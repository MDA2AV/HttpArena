module main

import fasthttp
import db.pg
import json
import os
import strings

struct Rating {
	score i64
	count i64
}

struct DatasetItem {
	id       i64
	name     string
	category string
	price    i64
	quantity i64
	active   bool
	tags     []string
	rating   Rating
}

struct DbItem {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
}

struct DbResp {
	items []DbItem
	count int
}

struct Shared {
mut:
	db       &pg.DB = unsafe { nil }
	dataset  []DatasetItem
	prefixes []string
}

fn handle(req fasthttp.HttpRequest) !fasthttp.HttpResponse {
	mut sh := unsafe { &Shared(req.user_data) }
	// Route on zero-copy tos() views into the request buffer — no per-request
	// bytestr()/all_before() heap allocation (each was a copy under the default GC,
	// i.e. collection pressure on every request).
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }

	if route == '/pipeline' {
		return resp('text/plain', 'ok'.bytes())
	} else if route == '/baseline11' {
		mut sum := qint(target, 'a') + qint(target, 'b')
		if method == 'POST' {
			sum += body_int(req)
		}
		return resp('text/plain', sum.str().bytes())
	} else if route == '/upload' {
		return resp('text/plain', req.body.len.str().bytes())
	} else if route.starts_with('/json/') {
		count := clamp_count(parse_u_at(route, 6), sh.dataset.len)
		mut m := qint(target, 'm')
		if m == 0 {
			m = 1
		}
		return fasthttp.HttpResponse{
			content:       sh.json_response(count, m)
			content_owned: true
		}
	} else if route == '/async-db' {
		return resp('application/json', sh.async_db(qint(target, 'min'), qint(target, 'max'), qint(target,
			'limit')).bytes())
	}
	return resp('text/plain', 'not found'.bytes())
}

// resp builds a full HTTP/1.1 response (status + headers + body).
fn resp(ctype string, body []u8) fasthttp.HttpResponse {
	mut sb := strings.new_builder(body.len + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(i64(body.len))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	unsafe { sb.write_ptr(body.data, body.len) }
	// content_owned: true → the backend takes the builder's buffer as-is and frees it
	// after sending, instead of cloning it (take_or_clone_content). That removes one
	// heap allocation per response (the clone) — halving response-path allocation
	// under the default GC.
	return fasthttp.HttpResponse{
		content:       sb
		content_owned: true
	}
}

// parse_u_at reads a non-negative integer from `s` starting at byte `start`, stopping
// at the first non-digit — no substring allocation (route[6..].i64() copies first).
@[direct_array_access]
fn parse_u_at(s string, start int) i64 {
	mut n := i64(0)
	for i := start; i < s.len; i++ {
		c := s[i]
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + i64(c - `0`)
	}
	return n
}

// json_response builds the full /json response in a single allocation (no
// per-request reflection; only `total` varies, the rest is a precomputed prefix).
fn (sh &Shared) json_response(count int, m i64) []u8 {
	mut clen := 21 + digits(i64(count))
	if count > 0 {
		clen += count - 1
	}
	for i in 0 .. count {
		t := sh.dataset[i].price * sh.dataset[i].quantity * m
		clen += sh.prefixes[i].len + digits(t) + 1
	}
	mut sb := strings.new_builder(clen + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: application/json\r\nContent-Length: ')
	sb.write_decimal(i64(clen))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string(sh.prefixes[i])
		sb.write_decimal(sh.dataset[i].price * sh.dataset[i].quantity * m)
		sb.write_u8(`}`)
	}
	sb.write_string('],"count":')
	sb.write_decimal(i64(count))
	sb.write_u8(`}`)
	return sb
}

fn (mut sh Shared) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	// db is pool-backed (Go-style db.pg): exec_param_many transparently acquires a
	// conn for the call and releases it back to the pool — no manual acquire/release.
	rows := sh.db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3', [
		min.str(),
		max.str(),
		lim.str(),
	]) or { return '{"items":[],"count":0}' }
	mut items := []DbItem{cap: rows.len}
	for row in rows {
		items << DbItem{
			id:       nn(row.vals[0]).int()
			name:     nn(row.vals[1])
			category: nn(row.vals[2])
			price:    nn(row.vals[3]).int()
			quantity: nn(row.vals[4]).int()
			active:   nn(row.vals[5]) == 't'
			tags:     json.decode([]string, nn3(row.vals[6], '[]')) or { [] }
			rating:   Rating{
				score: nn(row.vals[7]).i64()
				count: nn(row.vals[8]).i64()
			}
		}
	}
	return json.encode(DbResp{ items: items, count: items.len })
}

// body_int parses the request body as an integer, decoding chunked when present.
fn body_int(req fasthttp.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	raw := req.buffer[req.body.start..req.body.start + req.body.len].bytestr()
	headers :=
		req.buffer[req.header_fields.start..req.header_fields.start + req.header_fields.len].bytestr()
	if headers.to_lower().contains('transfer-encoding: chunked') {
		return dechunk(raw).i64()
	}
	return raw.i64()
}

fn dechunk(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		nl := s.index_after('\r\n', i) or { break }
		size := hex_int(s[i..nl])
		if size <= 0 {
			break
		}
		ds := nl + 2
		out.write_string(s[ds..ds + size])
		i = ds + size + 2
	}
	return out.str()
}

fn hex_int(s string) int {
	mut n := 0
	for c in s.trim_space() {
		d := if c >= `0` && c <= `9` {
			int(c - `0`)
		} else if c >= `a` && c <= `f` {
			int(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			int(c - `A` + 10)
		} else {
			break
		}
		n = n * 16 + d
	}
	return n
}

@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

// qint extracts a query parameter (after `key=`) from the request target.
fn qint(target string, key string) i64 {
	needle := key + '='
	idx := target.index(needle) or { return 0 }
	rest := target[idx + needle.len..]
	mut endp := rest.index('&') or { rest.len }
	return rest[..endp].i64()
}

fn clamp_count(n i64, max int) int {
	if n < 0 {
		return 0
	}
	if n > max {
		return max
	}
	return int(n)
}

fn digits(n i64) int {
	if n < 10 {
		return 1
	}
	mut x := n
	mut d := 0
	for x > 0 {
		d++
		x /= 10
	}
	return d
}

fn parse_db_url(u string) pg.Config {
	mut s := u
	if s.contains('://') {
		s = s.all_after('://')
	}
	creds := s.all_before('@')
	rest := s.all_after('@')
	host_port := rest.all_before('/')
	mut port := 5432
	if host_port.contains(':') {
		port = host_port.all_after(':').int()
	}
	return pg.Config{
		host:     host_port.all_before(':')
		port:     port
		user:     creds.all_before(':')
		password: creds.all_after(':')
		dbname:   rest.all_after('/')
	}
}

fn main() {
	url := os.getenv_opt('DATABASE_URL') or { 'postgres://bench:bench@localhost:5432/benchmark' }
	mut size := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int()
	if size < 1 {
		size = 64
	}
	if size > 200 {
		size = 200
	}
	// max_idle_conns MUST equal max_open_conns: db.pg defaults idle to 2, so any conn
	// released beyond the 2nd is physically closed and the next acquire pays a full PG
	// connect handshake — connection churn on every concurrent DB request. Keeping
	// idle == open makes it a fixed warm pool.
	mut db := pg.connect(parse_db_url(url), pg.PoolConfig{ max_open_conns: size, max_idle_conns: size })!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset := json.decode([]DatasetItem, os.read_file(dataset_path) or { '[]' }) or {
		[]DatasetItem{}
	}
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	mut sh := &Shared{
		db:       db
		dataset:  dataset
		prefixes: prefixes
	}

	mut server := fasthttp.new_server(fasthttp.ServerConfig{
		port:      8080
		handler:   handle
		user_data: sh
	})!
	server.run()!
}
