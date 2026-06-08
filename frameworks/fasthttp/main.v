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
	pool     pg.ConnectionPool
	dataset  []DatasetItem
	prefixes []string
}

fn handle(req fasthttp.HttpRequest) !fasthttp.HttpResponse {
	mut sh := unsafe { &Shared(req.user_data) }
	method := req.buffer[req.method.start..req.method.start + req.method.len].bytestr()
	target := req.buffer[req.path.start..req.path.start + req.path.len].bytestr()
	route := target.all_before('?')

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
		count := clamp_count(route[6..].i64(), sh.dataset.len)
		mut m := qint(target, 'm')
		if m == 0 {
			m = 1
		}
		return fasthttp.HttpResponse{
			content: sh.json_response(count, m)
		}
	} else if route == '/async-db' {
		return resp('application/json', sh.async_db(qint(target, 'min'), qint(target, 'max'),
			qint(target, 'limit')).bytes())
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
	return fasthttp.HttpResponse{
		content: sb
	}
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
	mut conn := sh.pool.acquire() or { return '{"items":[],"count":0}' }
	rows := conn.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		[min.str(), max.str(), lim.str()]) or {
		sh.pool.release(conn)
		return '{"items":[],"count":0}'
	}
	sh.pool.release(conn)
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
	headers := req.buffer[req.header_fields.start..req.header_fields.start +
		req.header_fields.len].bytestr()
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
	mut pool := pg.new_connection_pool(parse_db_url(url), size)!

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
		pool:     pool
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
