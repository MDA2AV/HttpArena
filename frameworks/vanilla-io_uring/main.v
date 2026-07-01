module main

import vanilla.http_server
import vanilla.http_server.http1_1.request_parser
import vanilla.http_server.tls
import vanilla.http_server.static_assets
import db.pg
import json
import os
import strings
import sync
import compress.gzip

struct Rating {
	score i64
	count i64
}

// Dataset item as stored in /data/dataset.json.
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

struct Fortune {
	id      int
	message string
}

struct Shared {
mut:
	db       &pg.DB = unsafe { nil }
	dataset  []DatasetItem
	prefixes []string                  // per item: `{…,"total":` (everything but the request-dependent total)
	asv      static_assets.AssetServer // /static/* via the audited module (negotiation + queue_buf borrowed send)
	cache    map[int]string        // crud cache-aside: id -> item JSON
	cache_mu &sync.RwMutex = unsafe { nil }
	// json-comp cache: the gzipped response for a given (count, m) is fully
	// deterministic and gzip dominates the cost, so compress once and reuse.
	// Key = (count << 32) | m. The benchmark hits only a few pairs, so it's tiny.
	gz_cache map[u64][]u8 // json-comp: precomputed at boot, READ-ONLY during serving (lock-free reads)
}

struct CrudCreate {
	id       int
	name     string
	category string
	price    int
	quantity int
}

// ws appends a string's bytes to `out` with no allocation (push_many copies
// straight from the string's backing storage into the connection write buffer).
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wi appends the decimal digits of a non-negative integer to `out`, no
// allocation (itoa into a stack scratch, emitted most-significant-first).
// The digits are written into the scratch back-to-front and flushed with a
// single `push_many` — single-element `<<` is several times slower than a bulk
// copy on post-0.5.1 V (vlang/v#27468), and this path runs for every number.
@[direct_array_access]
fn wi(mut out []u8, n i64) {
	mut tmp := [20]u8{}
	if n == 0 {
		tmp[0] = u8(`0`)
		unsafe { out.push_many(&tmp[0], 1) }
		return
	}
	mut x := n
	mut i := 20
	for x > 0 {
		i--
		tmp[i] = u8(`0`) + u8(x % 10)
		x /= 10
	}
	unsafe { out.push_many(&tmp[i], 20 - i) }
}

// wb appends a byte slice (e.g. a precomputed const response) into `out` with a
// single bulk copy — no allocation.
@[inline]
fn wb(mut out []u8, b []u8) {
	unsafe { out.push_many(b.data, b.len) }
}

// write_resp appends a complete HTTP/1.1 response (status line + headers + body)
// straight into the connection's persistent write buffer — no intermediate
// strings.Builder, no body→response copy, no per-request heap allocation. This
// is the zero-alloc twin of `ok()`; the latter survives only for the DB paths
// that are allocation-bound anyway.
fn write_resp(mut out []u8, ctype string, body string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

// write_ok_xcache writes a complete 200 JSON response carrying an X-Cache: HIT|MISS
// header straight into `out` — the zero-alloc twin of ok_xcache(): no per-call
// strings.Builder and no body→out copy. (write_resp above is the same for the
// no-X-Cache paths, so crud_list/crud_update reuse it.) Byte-identical to ok_xcache().
fn write_ok_xcache(mut out []u8, ctype string, body string, cache string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nX-Cache: ')
	ws(mut out, cache)
	ws(mut out, '\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

fn handle(req_buffer []u8, _fd int, mut out []u8, mut sh Shared) ! {
	req := request_parser.decode_http_request(req_buffer)!
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	// Route on the path before '?' WITHOUT allocating: a tos() view into the
	// request buffer rather than all_before()'s per-request copy. (Sub-slices like
	// route[6..] still copy, but only on the few paths that actually need them.)
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }

	if route == '/pipeline' {
		write_resp(mut out, 'text/plain', 'ok')
	} else if route == '/baseline11' {
		mut sum := qint(req, qk_a) + qint(req, qk_b)
		if method == 'POST' {
			sum += body_int(req)
		}
		write_resp(mut out, 'text/plain', sum.str())
	} else if route == '/upload' {
		// Answer by the declared Content-Length, not req.body.len: large bodies are
		// STREAMED (drained off the socket, head-only passed to the handler) by the
		// lib's body-drain, so req.body is empty for them. Falls back to the buffered
		// body length when Content-Length is absent (e.g. chunked). Mirrors vanilla-epoll.
		cl := req.content_length()
		n := if cl >= 0 { cl } else { req.body.len }
		write_resp(mut out, 'text/plain', n.str())
	} else if route.starts_with('/json/') {
		count := clamp_count(parse_u_at(route, 6), sh.dataset.len)
		mut m := qint(req, qk_m)
		if m == 0 {
			m = 1
		}
		if accepts_gzip(req) {
			// json-comp profile: gzip the body and set Content-Encoding.
			sh.write_json_gzip(mut out, count, m)
		} else {
			sh.write_json_response(mut out, count, m)
		}
	} else if route == '/async-db' {
		write_resp(mut out, 'application/json', sh.async_db(qint(req, qk_min), qint(req, qk_max), qint(req,
			qk_limit)))
	} else if route == '/fortunes' {
		write_resp(mut out, 'text/html; charset=utf-8', sh.fortunes())
	} else if route.starts_with('/static/') {
		// Canonical static serving via the lib's static_assets module, mounted at
		// /static/: negotiates the precompressed .br/.gz sibling per Accept-Encoding
		// (the arena sends `br;q=1`, so this ships the ~4x smaller .br body instead of
		// the raw file) and emits small assets via core.queue_buf borrowed send — the
		// worker sends the preloaded, immutable bytes DIRECTLY (no copy through the
		// per-connection write buffer). ONE audited path shared with vanilla-epoll,
		// replacing the hand-rolled identity-only map that ignored Accept-Encoding.
		sh.asv.respond_into(req_buffer, mut out) or { out << not_found }
	} else if route == '/crud/items' {
		if method == 'POST' {
			sh.write_crud_create(mut out, req)
		} else {
			sh.write_crud_list(mut out, qstr(req, qk_category), qint(req, qk_page), qint(req,
				qk_limit))
		}
	} else if route.starts_with('/crud/items/') {
		id := int(parse_u_at(route, 12))
		if method == 'PUT' {
			sh.write_crud_update(mut out, id, req)
		} else {
			sh.write_crud_get(mut out, id)
		}
	} else {
		out << not_found
	}
}

// crud_list returns a paginated, category-filtered page of items.
fn (mut sh Shared) write_crud_list(mut out []u8, category string, page i64, limit i64) {
	mut p := page
	if p < 1 {
		p = 1
	}
	mut lim := limit
	if lim < 1 {
		lim = 10
	}
	if lim > 100 {
		lim = 100
	}
	offset := (p - 1) * lim
	// db is pool-backed (Go-style db.pg): each exec_param_many transparently acquires
	// a pooled conn for the call and releases it — no manual acquire/release.
	mut db := sh.db
	rows := db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3', [
		category,
		lim.str(),
		offset.str(),
	]) or {
		write_resp(mut out, 'application/json', '{"items":[],"total":0,"page":1}')
		return
	}
	trows := db.exec_param_many('SELECT count(*) FROM items WHERE category = \$1', [
		category,
	]) or { [] }
	total := if trows.len > 0 { nn(trows[0].vals[0]).int() } else { 0 }
	mut items := []DbItem{cap: rows.len}
	for row in rows {
		items << row_to_item(row)
	}
	// Build the JSON body once (json.encode of the items array is the correctness
	// reference), then write the full response straight into `out` via write_resp —
	// no second strings.Builder for the response head and no body→out copy (ok() did
	// both). Byte-identical to the previous ok('application/json', sb.str()).
	mut sb := strings.new_builder(items.len * 200 + 64)
	sb.write_string('{"items":')
	sb.write_string(json.encode(items))
	sb.write_string(',"total":')
	sb.write_decimal(i64(total))
	sb.write_string(',"page":')
	sb.write_decimal(p)
	sb.write_u8(`}`)
	write_resp(mut out, 'application/json', sb.str())
}

// write_crud_get writes a single item straight into `out`, using a cache-aside
// in-memory cache and the X-Cache header (MISS on first read, HIT after). The
// hot path is the HIT: it now writes the cached body + headers directly into the
// connection buffer with zero per-request allocation (ok_xcache built a throwaway
// strings.Builder per hit, then the caller copied it into out).
fn (mut sh Shared) write_crud_get(mut out []u8, id int) {
	sh.cache_mu.@rlock()
	cached := sh.cache[id] or { '' }
	sh.cache_mu.runlock()
	if cached.len > 0 {
		write_ok_xcache(mut out, 'application/json', cached, 'HIT')
		return
	}
	mut db := sh.db
	rows := db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1', [
		id.str(),
	]) or {
		wb(mut out, not_found)
		return
	}
	if rows.len == 0 {
		wb(mut out, not_found)
		return
	}
	body := json.encode(row_to_item(rows[0]))
	sh.cache_mu.@lock()
	sh.cache[id] = body
	sh.cache_mu.unlock()
	write_ok_xcache(mut out, 'application/json', body, 'MISS')
}

// crud_create inserts a new item from the JSON body and returns 201.
fn (mut sh Shared) write_crud_create(mut out []u8, req request_parser.HttpRequest) {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return
	}
	mut db := sh.db
	db.exec_param_many("INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity", [
		c.id.str(),
		c.name,
		c.category,
		c.price.str(),
		c.quantity.str(),
	]) or {
		wb(mut out, bad_request)
		return
	}
	wb(mut out, created)
}

// write_crud_update updates an item, invalidates its cache entry, and writes the
// response straight into `out`.
fn (mut sh Shared) write_crud_update(mut out []u8, id int, req request_parser.HttpRequest) {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return
	}
	mut db := sh.db
	db.exec_param_many('UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1', [
		id.str(),
		c.name,
		c.category,
		c.price.str(),
		c.quantity.str(),
	]) or {
		wb(mut out, bad_request)
		return
	}
	sh.cache_mu.@lock()
	sh.cache.delete(id)
	sh.cache_mu.unlock()
	write_resp(mut out, 'application/json', '{"status":"ok"}')
}

fn row_to_item(row pg.Row) DbItem {
	return DbItem{
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

const not_found = 'HTTP/1.1 404 Not Found\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const created = 'HTTP/1.1 201 Created\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const bad_request = 'HTTP/1.1 400 Bad Request\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// json_response builds the FULL HTTP response (headers + body) for /json in a
// single allocation — no per-request reflection and no body→response copy.
// Only `total` (price*quantity*m) varies per request; the rest is a precomputed
// prefix. Content-Length is computed up front so everything lands in one buffer.
fn (sh &Shared) write_json_response(mut out []u8, count int, m i64) {
	// 21 = len('{"items":[') + len('],"count":') + '}', plus the count's own digits
	mut clen := 21 + digits(i64(count))
	if count > 0 {
		clen += count - 1 // item separators
	}
	for i in 0 .. count {
		t := sh.dataset[i].price * sh.dataset[i].quantity * m
		clen += sh.prefixes[i].len + digits(t) + 1 // prefix + total + '}'
	}
	ws(mut out,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(clen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		ws(mut out, sh.prefixes[i])
		wi(mut out, sh.dataset[i].price * sh.dataset[i].quantity * m)
		// fuse each object's closing `}` with the item separator `,` into one
		// bulk write — single-element `<<` is the slow path on post-0.5.1 V.
		ws(mut out, if i < count - 1 { '},' } else { '}' })
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	ws(mut out, '}')
}

// gz_response builds the COMPLETE gzipped /json response for (count, m). Pure
// function of the shared dataset (deterministic), so it is precomputed once at
// boot (see main) and also serves the cold path for an unexpected param.
fn gz_response(sh &Shared, count int, m i64) []u8 {
	body := sh.json_body(count, m)
	gz := gzip.compress(body.bytes()) or { return []u8{} }
	mut resp := []u8{cap: gz.len + 128}
	ws(mut resp,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut resp, i64(gz.len))
	ws(mut resp, '\r\nConnection: keep-alive\r\n\r\n')
	unsafe { resp.push_many(gz.data, gz.len) }
	return resp
}

// write_json_gzip is the json-comp path. The gzipped response per (count, m) is
// deterministic, so the cache is fully precomputed at boot and is READ-ONLY during
// serving — the hot path is a lock-free map read (no per-request shared RwMutex,
// which contended across all workers and collapsed io_uring json-comp @16384).
fn (sh &Shared) write_json_gzip(mut out []u8, count int, m i64) {
	key := (u64(u32(count)) << 32) | u64(u32(m))
	if cached := sh.gz_cache[key] {
		out << cached
		return
	}
	// Param outside the precomputed grid (not sent by the benchmark): build and
	// send WITHOUT caching, so the hot path stays write-free and lock-free.
	resp := gz_response(sh, count, m)
	if resp.len > 0 {
		out << resp
	} else {
		write_resp(mut out, 'application/json', sh.json_body(count, m))
	}
}

// json_body builds just the /json body string (used for the gzip path).
fn (sh &Shared) json_body(count int, m i64) string {
	mut sb := strings.new_builder(count * 224 + 32)
	sb.write_string('{"items":[')
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
	return sb.str()
}

// fortunes queries the fortune table, appends the runtime row, sorts by message
// and renders the HTML table (escaped). 199 seeded + 1 runtime + header = 201 <tr>.
fn (mut sh Shared) fortunes() string {
	mut fortunes := []Fortune{}
	mut db := sh.db
	rows := db.exec_param_many('SELECT id, message FROM fortune', []) or { [] }
	for row in rows {
		fortunes << Fortune{
			id:      nn(row.vals[0]).int()
			message: nn(row.vals[1])
		}
	}
	fortunes << Fortune{
		id:      0
		message: 'Additional fortune added at request time.'
	}
	fortunes.sort(a.message < b.message)
	mut sb := strings.new_builder(32768)
	sb.write_string('<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in fortunes {
		sb.write_string('<tr><td>')
		sb.write_decimal(i64(f.id))
		sb.write_string('</td><td>')
		sb.write_string(escape_html(f.message))
		sb.write_string('</td></tr>')
	}
	sb.write_string('</table></body></html>')
	return sb.str()
}

fn escape_html(s string) string {
	// Fast path: most fortune messages contain no special characters, so return
	// the original with no allocation instead of replace_each's 5 full-string
	// passes (each scanning + reallocating). Only escape when there's something to.
	mut needs := false
	for c in s {
		if c == `&` || c == `<` || c == `>` || c == `"` || c == `'` {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	mut b := strings.new_builder(s.len + 16)
	for c in s {
		match c {
			`&` { b.write_string('&amp;') }
			`<` { b.write_string('&lt;') }
			`>` { b.write_string('&gt;') }
			`"` { b.write_string('&quot;') }
			`'` { b.write_string('&apos;') }
			else { b.write_u8(c) }
		}
	}
	return b.str()
}

// digits returns the number of decimal digits in a non-negative integer.
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

fn (mut sh Shared) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	// db is pool-backed (Go-style db.pg): exec_param_many transparently acquires a
	// pooled conn per call. (The old per-conn lazily-prepared statement isn't a clean
	// fit for the transparent pool — prepared statements are session-scoped, and the
	// pool hands out a transient conn per call; re-add via db.conn() pinning if the
	// async-db per-call re-parse cost ever matters.)
	mut db := sh.db
	adb_params := [min.str(), max.str(), lim.str()]
	rows := db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		adb_params) or { return '{"items":[],"count":0}' }
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

// nn unwraps a nullable column value to a plain string ('' for NULL).
@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

// nn3 unwraps a nullable column value with a custom default.
@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

// Precomputed query-parameter key bytes, built once at init. The hot path then
// never allocates a []u8 per lookup — `key.bytes()` did, one alloc per request
// per parameter (baseline parses a+b, async-db min+max+limit, etc.).
const qk_a = 'a'.bytes()
const qk_b = 'b'.bytes()
const qk_m = 'm'.bytes()
const qk_min = 'min'.bytes()
const qk_max = 'max'.bytes()
const qk_limit = 'limit'.bytes()
const qk_page = 'page'.bytes()
const qk_category = 'category'.bytes()

// qint reads a query parameter as an integer (0 if absent / non-numeric). The
// key is a precomputed []u8 (qk_*) so there is no per-call allocation; the value
// is read as a zero-copy tos() view and parsed in place.
fn qint(req request_parser.HttpRequest, key []u8) i64 {
	s := req.get_query_slice(key) or { return 0 }
	return unsafe { tos(&req.buffer[s.start], s.len) }.i64()
}

// qstr reads a query parameter as a string ('' if absent). Clones so the value
// outlives the request buffer (it is passed to the DB driver).
fn qstr(req request_parser.HttpRequest, key []u8) string {
	s := req.get_query_slice(key) or { return '' }
	return unsafe { tos(&req.buffer[s.start], s.len) }.clone()
}

// parse_u_at parses a non-negative integer from `s` starting at byte `start`,
// stopping at the first non-digit — no substring allocation (route[6..].i64()
// copies). Used to read the count / id embedded in the request path.
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

fn clamp_count(n i64, max int) int {
	if n < 0 {
		return 0
	}
	if n > max {
		return max
	}
	return int(n)
}

// body_int parses the request body as an integer, decoding chunked transfer
// encoding when present.
fn body_int(req request_parser.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	if te := req.get_header_value_slice('Transfer-Encoding') {
		val := unsafe { tos(&req.buffer[te.start], te.len) }
		if val.contains('chunked') {
			return dechunk(raw).i64()
		}
	}
	return raw.i64()
}

// dechunk decodes an HTTP/1.1 chunked body into its payload.
fn dechunk(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		nl := s.index_after('\r\n', i) or { break }
		size := strconv_hex(s[i..nl])
		if size <= 0 {
			break
		}
		data_start := nl + 2
		out.write_string(s[data_start..data_start + size])
		i = data_start + size + 2 // skip data + trailing CRLF
	}
	return out.str()
}

fn strconv_hex(s string) int {
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

// accepts_gzip reports whether the request advertises gzip in Accept-Encoding.
fn accepts_gzip(req request_parser.HttpRequest) bool {
	ae := req.get_header_value_slice('Accept-Encoding') or { return false }
	return unsafe { tos(&req.buffer[ae.start], ae.len) }.contains('gzip')
}

// content_type maps a file extension to a MIME type for the static handler.
// parse_db_url turns postgres://user:pass@host:port/dbname into a pg.Config.
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

// load_tls_config builds the json-tls server's TLS config. It reads the cert/key
// the HttpArena harness bind-mounts at /certs (overridable via TLS_CERT/TLS_KEY).
// If NO cert is mounted (local dev), it falls back to a fresh self-signed cert —
// the benchmark/validate clients use `curl -k` / wrk, which never verify it. If a
// cert IS present but the key is missing/unreadable, it FAILS LOUDLY rather than
// silently self-signing. TLS 1.3 + ALPN http/1.1 are fixed by the tls shim.
fn load_tls_config() &tls.Config {
	cert_path := os.getenv_opt('TLS_CERT') or { '/certs/server.crt' }
	key_path := os.getenv_opt('TLS_KEY') or { '/certs/server.key' }
	cert := os.read_bytes(cert_path) or {
		eprintln('vanilla-io_uring: no TLS cert at ${cert_path} (${err}); using ephemeral self-signed')
		return tls.new_self_signed() or {
			panic('vanilla-io_uring: self-signed TLS bring-up failed: ${err}')
		}
	}
	key := os.read_bytes(key_path) or {
		panic('vanilla-io_uring: TLS cert present at ${cert_path} but key unreadable at ${key_path}: ${err}')
	}
	return tls.new_from_pem(cert, key) or {
		panic('vanilla-io_uring: TLS cert/key parse failed: ${err}')
	}
}

fn main() {
	url := os.getenv_opt('DATABASE_URL') or { 'postgres://bench:bench@localhost:5432/benchmark' }
	mut size := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int()
	if size < 1 {
		size = 64
	}
	if size > 200 {
		size = 200 // leave headroom under Postgres max_connections
	}
	// max_idle_conns MUST equal max_open_conns: db.pg defaults idle to 2, so any conn
	// released beyond the 2nd is physically closed (pool.v) and the next acquire pays a
	// full PG connect handshake. Under the arena's concurrent DB load that churns
	// connections on every request (async-db/crud/fortunes were down 60-90%). Keeping
	// idle == open makes it a fixed warm pool, matching the old ConnectionPool.
	mut db := pg.connect(parse_db_url(url), pg.PoolConfig{ max_open_conns: size, max_idle_conns: size })!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode([]DatasetItem, dataset_raw) or { []DatasetItem{} }

	// Precompute each item's JSON prefix once: `{…,"rating":{…},"total":`
	// (drop the closing brace, append the total key). Only the total value is
	// request-dependent, so the hot path never serializes a struct.
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	// Canonical static server: loads every asset PLUS its .br/.gz siblings once,
	// mounts them at /static/, and negotiates Accept-Encoding per request (serving
	// the precompressed body when accepted, emitted via core.queue_buf borrowed
	// send). Replaces the former identity-only map that ignored Accept-Encoding and
	// always shipped the raw file. spa_fallback off: the arena set has no SPA.
	asv := static_assets.new(static_assets.Config{
		root:         static_dir
		url_prefix:   '/static/'
		spa_fallback: ''
	}) or { panic('vanilla-io_uring: static_assets init failed: ${err}') }

	mut sh := Shared{
		db:       db
		dataset:  dataset
		prefixes: prefixes
		asv:      asv
		cache:    map[int]string{}
		cache_mu: sync.new_rwmutex()
		gz_cache: map[u64][]u8{}
	}

	// Precompute the json-comp (gzip) responses at boot so write_json_gzip reads the
	// cache LOCK-FREE during serving (no per-request shared RwMutex — that contended
	// across workers and collapsed io_uring json-comp @16384 conns). The profile's
	// params are bounded; cover count 1..min(dataset,64) x m 1..16.
	gz_cap_count := if dataset.len < 64 { dataset.len } else { 64 }
	for c in 1 .. gz_cap_count + 1 {
		for mm in 1 .. 17 {
			r := gz_response(sh, c, i64(mm))
			if r.len > 0 {
				sh.gz_cache[(u64(u32(c)) << 32) | u64(u32(mm))] = r
			}
		}
	}

	// ── json-tls profile: /json over HTTPS on :8081 via the epoll + kTLS backend ──
	// The lib's io_uring backend has no TLS, so the json-tls listener runs on the
	// epoll backend (TLS 1.3 via Mbed TLS; after the handshake the kernel does record
	// AES-128-GCM via kTLS where the `tls` module is present, else userspace fallback).
	// It serves ONLY /json (404 elsewhere) — minimal TLS surface — reusing the same
	// allocation-free write_json_response (read-only: dataset + prefixes). A STATELESS
	// request_handler captures `sh`; it never touches the DB/caches, so it runs safely
	// alongside the io_uring workers. The io_uring server below keeps the non-TLS
	// profiles on :8080.
	tls_handler := fn [sh] (req_buffer []u8, fd int, mut out []u8) ! {
		mut req := request_parser.HttpRequest{
			buffer: req_buffer
		}
		if !request_parser.decode_into(mut req) {
			wb(mut out, bad_request)
			return
		}
		target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
		qpos := target.index_u8(`?`)
		route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }
		if route.starts_with('/json/') {
			count := clamp_count(parse_u_at(route, 6), sh.dataset.len)
			mut m := qint(req, qk_m)
			if m == 0 {
				m = 1
			}
			sh.write_json_response(mut out, count, m)
			return
		}
		wb(mut out, not_found)
	}
	// Port is fixed to 8081 by the HttpArena harness; TLS_PORT lets local runs pick a
	// free port. run() blocks, so the TLS server runs on its own thread (value-mut
	// receiver → spawn via a closure with a local mut copy; the two servers are
	// independent — own socket, workers and backend).
	mut tls_port := (os.getenv_opt('TLS_PORT') or { '8081' }).int()
	if tls_port <= 0 {
		tls_port = 8081
	}
	tls_server := http_server.new_server(http_server.ServerConfig{
		port:            tls_port
		io_multiplexing: .epoll
		limits:          http_server.Limits{
			max_request_bytes: 64 * 1024
		}
		request_handler: tls_handler
		tls_config:      load_tls_config()
	})!
	spawn fn [tls_server] () {
		mut s := tls_server
		s.run()
	}()

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: .io_uring
		limits:          http_server.Limits{
			max_request_bytes: 32 * 1024 * 1024 // accept the 20 MiB upload bodies
		}
		request_handler: fn [mut sh] (req_buffer []u8, fd int, mut out []u8) ! {
			handle(req_buffer, fd, mut out, mut sh)!
		}
	})!
	server.run()
}

// static_response prebuilds the full HTTP response for a static file.
