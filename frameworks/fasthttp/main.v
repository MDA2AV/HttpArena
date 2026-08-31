module main

import fasthttp
import db.pg
import json2
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

struct CrudCreate {
	id       int
	name     string
	category string
	price    int
	quantity int
}

// StaticFile is a preloaded static asset: its on-disk path, negotiated
// Content-Type and byte size. The body itself is streamed with sendfile(2) via
// ResponseControl.file_path — never copied through the response buffer.
struct StaticFile {
	path  string
	ctype string
	size  i64
}

// Shared is the process-wide, reference-shared state handed to every request as
// HttpRequest.user_data. The dataset/prefixes/static map are read-only after
// boot (no lock); the DB pool is internally thread-safe (Go-style db.pg); the
// crud and gzip caches are mutable and mutex-guarded because SO_REUSEPORT routes
// requests for the same key to different worker threads (the crud X-Cache
// MISS→HIT probe must survive that routing, so the cache cannot be per-worker).
struct Shared {
mut:
	db       &pg.DB = unsafe { nil }
	dataset  []DatasetItem
	prefixes []string
	statics  map[string]StaticFile
	crud     map[int]string // id -> rendered item JSON (cache-aside body)
	crud_mu  &sync.RwMutex = unsafe { nil }
	gz       map[u64]string // (count<<32)|m -> full gzipped /json response bytes
	gz_mu    &sync.RwMutex = unsafe { nil }
}

// WorkerCtx is the per-worker (per-thread) state built once by make_state and
// reached through the append handler's `worker_state`. A worker serves requests
// one at a time (the epoll loop calls the handler synchronously), so its reused
// render buffer needs no locking. It exists to keep the JSON/HTML DB responses
// off the per-request allocator on the hot paths.
struct WorkerCtx {
mut:
	scratch []u8
}

// ── append helpers (write straight into the connection's reused buffer) ──────

@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

@[inline]
fn wb(mut out []u8, b []u8) {
	unsafe { out.push_many(b.data, b.len) }
}

@[direct_array_access]
fn wi(mut out []u8, n i64) {
	mut tmp := [20]u8{}
	if n == 0 {
		tmp[0] = u8(`0`)
		unsafe { out.push_many(&tmp[0], 1) }
		return
	}
	neg := n < 0
	mut x := u64(n)
	if neg {
		x = u64(-(n + 1)) + 1
	}
	mut i := 20
	for x > 0 {
		i--
		tmp[i] = u8(`0`) + u8(x % 10)
		x /= 10
	}
	if neg {
		i--
		tmp[i] = u8(`-`)
	}
	unsafe { out.push_many(&tmp[i], 20 - i) }
}

// ws_json_str appends `s` as a JSON string value (no surrounding quotes),
// escaping the characters JSON requires. Fast path: emit as one copy when the
// value is clean (the common case for dataset names/categories).
@[direct_array_access]
fn ws_json_str(mut out []u8, s string) {
	mut needs := false
	for c in s {
		if c == `"` || c == `\\` || c < 0x20 {
			needs = true
			break
		}
	}
	if !needs {
		ws(mut out, s)
		return
	}
	for c in s {
		match c {
			`"` { ws(mut out, '\\"') }
			`\\` { ws(mut out, '\\\\') }
			`\n` { ws(mut out, '\\n') }
			`\r` { ws(mut out, '\\r') }
			`\t` { ws(mut out, '\\t') }
			else { unsafe { out.push_many(&c, 1) } }
		}
	}
}

// escape_html_into HTML-escapes `s` straight into `out`. Fast path: one bulk copy
// when nothing needs escaping.
@[direct_array_access]
fn escape_html_into(mut out []u8, s string) {
	mut needs := false
	for c in s {
		if c == `&` || c == `<` || c == `>` || c == `"` || c == `'` {
			needs = true
			break
		}
	}
	if !needs {
		ws(mut out, s)
		return
	}
	for c in s {
		match c {
			`&` { ws(mut out, '&amp;') }
			`<` { ws(mut out, '&lt;') }
			`>` { ws(mut out, '&gt;') }
			`"` { ws(mut out, '&quot;') }
			`'` { ws(mut out, '&apos;') }
			else { unsafe { out.push_many(&c, 1) } }
		}
	}
}

// emit writes a complete 200 response with a precomputed body into `out`.
fn emit(mut out []u8, ctype string, body []u8) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, body)
}

fn write_resp(mut out []u8, ctype string, body string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

// emit_xcache writes a 200 JSON response carrying an X-Cache: HIT|MISS header —
// the shared framing for both crud GET paths.
fn emit_xcache(mut out []u8, body string, cache string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nX-Cache: ')
	ws(mut out, cache)
	ws(mut out, '\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

const pipeline_resp = 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

const not_found = 'HTTP/1.1 404 Not Found\r\nServer: fasthttp\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const created = 'HTTP/1.1 201 Created\r\nServer: fasthttp\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const bad_request = 'HTTP/1.1 400 Bad Request\r\nServer: fasthttp\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// ── the append handler ───────────────────────────────────────────────────────

fn handle(req fasthttp.HttpRequest, mut out []u8, worker_state voidptr, mut ctl fasthttp.ResponseControl) fasthttp.Step {
	mut sh := unsafe { &Shared(req.user_data) }
	mut w := unsafe { &WorkerCtx(worker_state) }

	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	if target == '/pipeline' {
		wb(mut out, pipeline_resp)
		return .done
	}
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }

	if route == '/baseline11' {
		mut sum := qint(target, 'a') + qint(target, 'b')
		if method == 'POST' {
			sum += body_int(req)
		}
		w.emit_int(mut out, sum)
		return .done
	} else if route == '/echo' {
		echo_body(mut out, req)
		return .done
	} else if route.starts_with('/json/') {
		count := clamp_count(parse_u_at(route, 6), sh.dataset.len)
		mut m := qint(target, 'm')
		if m == 0 {
			m = 1
		}
		if accepts_gzip(req) {
			sh.write_json_gzip(mut out, count, m)
		} else {
			sh.write_json_response(mut out, count, m)
		}
		return .done
	} else if route == '/async-db' {
		sh.async_db(mut w, mut out, qint(target, 'min'), qint(target, 'max'), qint(target,
			'limit'))
		return .done
	} else if route == '/fortunes' {
		sh.fortunes(mut w, mut out)
		return .done
	} else if route.starts_with('/static/') {
		name := route[8..]
		if sf := sh.statics[name] {
			ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: ')
			ws(mut out, sf.ctype)
			ws(mut out, '\r\nContent-Length: ')
			wi(mut out, sf.size)
			ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
			ctl.file_path = sf.path // reactor streams the body with sendfile(2)
		} else {
			wb(mut out, not_found)
		}
		return .done
	} else if route == '/crud/items' {
		if method == 'POST' {
			sh.crud_create(mut out, req)
		} else {
			sh.crud_list(mut w, mut out, qstr(target, 'category'), qint(target, 'page'),
				qint(target, 'limit'))
		}
		return .done
	} else if route.starts_with('/crud/items/') {
		id := int(parse_u_at(route, 12))
		if method == 'PUT' {
			sh.crud_update(mut out, id, req)
		} else {
			sh.crud_get(mut w, mut out, id)
		}
		return .done
	}
	wb(mut out, not_found)
	return .done
}

// emit_int writes a 200 text/plain response whose body is a single integer,
// formatted into the reused per-worker scratch (no per-request int->string).
fn (mut w WorkerCtx) emit_int(mut out []u8, n i64) {
	unsafe { w.scratch.len = 0 }
	wi(mut w.scratch, n)
	emit(mut out, 'text/plain', w.scratch)
}

// ── /echo ────────────────────────────────────────────────────────────────────

// echo_body hands the request body back byte for byte. The parser exposes the
// RAW body region, so a chunked request still carries its framing here and is
// decoded first: the response is framed from the bytes that actually arrived,
// never from Content-Length (a chunked POST carries none). Nothing goes through
// a string on the way out either, so any byte value survives the round trip.
fn echo_body(mut out []u8, req fasthttp.HttpRequest) {
	if header_val(req, 'transfer-encoding').contains('chunked') {
		emit(mut out, 'application/octet-stream', dechunk(req.buffer, req.body.start,
			req.body.len))
		return
	}
	body := unsafe { req.buffer[req.body.start..req.body.start + req.body.len] }
	emit(mut out, 'application/octet-stream', body)
}

// ── /json (non-DB) ───────────────────────────────────────────────────────────

// write_json_response builds the whole /json response in a single pass straight
// into `out`: Content-Length is precomputed from the same values the body emits,
// so the framed length can never desync from the body.
fn (sh &Shared) write_json_response(mut out []u8, count int, m i64) {
	mut clen := 21 + digits(i64(count))
	if count > 0 {
		clen += count - 1
	}
	for i in 0 .. count {
		t := sh.dataset[i].price * sh.dataset[i].quantity * m
		clen += sh.prefixes[i].len + digits(t) + 1
	}
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(clen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		ws(mut out, sh.prefixes[i])
		wi(mut out, sh.dataset[i].price * sh.dataset[i].quantity * m)
		ws(mut out, if i < count - 1 { '},' } else { '}' })
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	ws(mut out, '}')
}

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

// write_json_gzip is the json-comp path: a process-shared, RwMutex-guarded cache
// of complete gzipped responses keyed by (count<<32)|m. Compress once on the
// first miss, then blit the cached bytes on every hit (the profile is
// compression-bound).
fn (mut sh Shared) write_json_gzip(mut out []u8, count int, m i64) {
	key := (u64(u32(count)) << 32) | u64(u32(m))
	sh.gz_mu.@rlock()
	cached := sh.gz[key] or { '' }
	sh.gz_mu.runlock()
	if cached.len > 0 {
		ws(mut out, cached)
		return
	}
	body := sh.json_body(count, m)
	gz := gzip.compress(body.bytes()) or {
		write_resp(mut out, 'application/json', body)
		return
	}
	mut resp := []u8{cap: gz.len + 128}
	ws(mut resp, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut resp, i64(gz.len))
	ws(mut resp, '\r\nConnection: keep-alive\r\n\r\n')
	unsafe { resp.push_many(gz.data, gz.len) }
	resp_s := resp.bytestr()
	sh.gz_mu.@lock()
	if sh.gz.len < 1024 {
		sh.gz[key] = resp_s
	}
	sh.gz_mu.unlock()
	ws(mut out, resp_s)
}

// ── DB item rendering (text protocol → JSON, into the worker scratch) ─────────

@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

// render_item appends one items-row as a JSON object into `out`. `tags` is a
// JSONB column, which libpq returns already serialized as JSON text, so it is
// emitted raw (no decode/re-encode round-trip).
fn render_item(mut out []u8, row pg.Row) {
	ws(mut out, '{"id":')
	ws(mut out, nn(row.vals[0]))
	ws(mut out, ',"name":"')
	ws_json_str(mut out, nn(row.vals[1]))
	ws(mut out, '","category":"')
	ws_json_str(mut out, nn(row.vals[2]))
	ws(mut out, '","price":')
	ws(mut out, nn(row.vals[3]))
	ws(mut out, ',"quantity":')
	ws(mut out, nn(row.vals[4]))
	ws(mut out, ',"active":')
	ws(mut out, if nn(row.vals[5]) == 't' { 'true' } else { 'false' })
	ws(mut out, ',"tags":')
	ws(mut out, nn3(row.vals[6], '[]'))
	ws(mut out, ',"rating":{"score":')
	ws(mut out, nn(row.vals[7]))
	ws(mut out, ',"count":')
	ws(mut out, nn(row.vals[8]))
	ws(mut out, '}}')
}

// ── /async-db ────────────────────────────────────────────────────────────────

const async_db_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3'

fn (mut sh Shared) async_db(mut w WorkerCtx, mut out []u8, min i64, max i64, limit i64) {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	rows := sh.db.exec_param_many(async_db_sql, [min.str(), max.str(), lim.str()]) or {
		write_resp(mut out, 'application/json', '{"items":[],"count":0}')
		return
	}
	unsafe { w.scratch.len = 0 }
	ws(mut w.scratch, '{"items":[')
	for i, row in rows {
		if i > 0 {
			ws(mut w.scratch, ',')
		}
		render_item(mut w.scratch, row)
	}
	ws(mut w.scratch, '],"count":')
	wi(mut w.scratch, i64(rows.len))
	ws(mut w.scratch, '}')
	emit(mut out, 'application/json', w.scratch)
}

// ── /crud ──────────────────────────────────────────────────────────────────

const crud_list_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3'

fn (mut sh Shared) crud_list(mut w WorkerCtx, mut out []u8, category string, page i64, limit i64) {
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
	rows := sh.db.exec_param_many(crud_list_sql, [category, lim.str(), offset.str()]) or {
		write_resp(mut out, 'application/json', '{"items":[],"total":0,"page":1}')
		return
	}
	mut total := i64(0)
	unsafe { w.scratch.len = 0 }
	ws(mut w.scratch, '{"items":[')
	for i, row in rows {
		if i > 0 {
			ws(mut w.scratch, ',')
		}
		render_item(mut w.scratch, row)
		total = nn(row.vals[9]).i64()
	}
	ws(mut w.scratch, '],"total":')
	wi(mut w.scratch, total)
	ws(mut w.scratch, ',"page":')
	wi(mut w.scratch, p)
	ws(mut w.scratch, '}')
	emit(mut out, 'application/json', w.scratch)
}

const crud_get_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1'

fn (mut sh Shared) crud_get(mut w WorkerCtx, mut out []u8, id int) {
	// Cache-aside: a HIT answers with no DB round-trip.
	sh.crud_mu.@rlock()
	cached := sh.crud[id] or { '' }
	sh.crud_mu.runlock()
	if cached.len > 0 {
		emit_xcache(mut out, cached, 'HIT')
		return
	}
	rows := sh.db.exec_param_many(crud_get_sql, [id.str()]) or {
		wb(mut out, not_found)
		return
	}
	if rows.len == 0 {
		wb(mut out, not_found)
		return
	}
	unsafe { w.scratch.len = 0 }
	render_item(mut w.scratch, rows[0])
	body := w.scratch.bytestr()
	sh.crud_mu.@lock()
	if sh.crud.len < 100000 {
		sh.crud[id] = body
	}
	sh.crud_mu.unlock()
	emit_xcache(mut out, body, 'MISS')
}

const crud_insert_sql = "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity"

fn (mut sh Shared) crud_create(mut out []u8, req fasthttp.HttpRequest) {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json2.decode[CrudCreate](raw) or {
		wb(mut out, bad_request)
		return
	}
	sh.db.exec_param_many(crud_insert_sql, [c.id.str(), c.name, c.category, c.price.str(),
		c.quantity.str()]) or {
		wb(mut out, bad_request)
		return
	}
	wb(mut out, created)
}

const crud_update_sql = 'UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1'

fn (mut sh Shared) crud_update(mut out []u8, id int, req fasthttp.HttpRequest) {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json2.decode[CrudCreate](raw) or {
		wb(mut out, bad_request)
		return
	}
	sh.db.exec_param_many(crud_update_sql, [id.str(), c.name, c.category, c.price.str(),
		c.quantity.str()]) or {
		wb(mut out, bad_request)
		return
	}
	// Invalidate the cache slot (cache-aside, invalidate-on-write).
	sh.crud_mu.@lock()
	sh.crud.delete(id)
	sh.crud_mu.unlock()
	write_resp(mut out, 'application/json', '{"status":"ok"}')
}

// ── /fortunes ────────────────────────────────────────────────────────────────

struct Fortune {
	id      int
	message string
}

const synthetic_fortune = 'Additional fortune added at request time.'

fn (mut sh Shared) fortunes(mut w WorkerCtx, mut out []u8) {
	mut rows_out := []Fortune{}
	rows := sh.db.exec_param_many('SELECT id, message FROM fortune', []) or { []pg.Row{} }
	for row in rows {
		rows_out << Fortune{
			id:      nn(row.vals[0]).int()
			message: nn(row.vals[1])
		}
	}
	rows_out << Fortune{
		id:      0
		message: synthetic_fortune
	}
	rows_out.sort_with_compare(fn (a &Fortune, b &Fortune) int {
		return compare_strings(a.message, b.message)
	})
	unsafe { w.scratch.len = 0 }
	ws(mut w.scratch, '<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in rows_out {
		ws(mut w.scratch, '<tr><td>')
		wi(mut w.scratch, i64(f.id))
		ws(mut w.scratch, '</td><td>')
		escape_html_into(mut w.scratch, f.message)
		ws(mut w.scratch, '</td></tr>')
	}
	ws(mut w.scratch, '</table></body></html>')
	emit(mut out, 'text/html; charset=utf-8', w.scratch)
}

// ── request helpers ──────────────────────────────────────────────────────────

// qint extracts an integer query parameter (after `key=`) from the request target.
fn qint(target string, key string) i64 {
	needle := key + '='
	idx := target.index(needle) or { return 0 }
	rest := target[idx + needle.len..]
	endp := rest.index('&') or { rest.len }
	return rest[..endp].i64()
}

// qstr extracts a string query parameter value from the request target.
fn qstr(target string, key string) string {
	needle := key + '='
	idx := target.index(needle) or { return '' }
	rest := target[idx + needle.len..]
	endp := rest.index('&') or { rest.len }
	return rest[..endp]
}

// header_val returns the (trimmed) value of the header named `lname` (given in
// lowercase) from the request head, or '' if absent. Case-insensitive on the name.
@[direct_array_access]
fn header_val(req fasthttp.HttpRequest, lname string) string {
	hs := req.header_fields.start
	he := hs + req.header_fields.len
	mut i := hs
	for i < he {
		mut le := i
		for le < he && req.buffer[le] != `\n` {
			le++
		}
		mut lineend := le
		if lineend > i && req.buffer[lineend - 1] == `\r` {
			lineend--
		}
		// find ':'
		mut colon := i
		for colon < lineend && req.buffer[colon] != `:` {
			colon++
		}
		if colon < lineend && colon - i == lname.len {
			mut matched := true
			for j in 0 .. lname.len {
				mut ch := req.buffer[i + j]
				if ch >= `A` && ch <= `Z` {
					ch += 32
				}
				if ch != lname[j] {
					matched = false
					break
				}
			}
			if matched {
				mut vs := colon + 1
				for vs < lineend && (req.buffer[vs] == ` ` || req.buffer[vs] == `\t`) {
					vs++
				}
				mut ve := lineend
				for ve > vs && (req.buffer[ve - 1] == ` ` || req.buffer[ve - 1] == `\t`) {
					ve--
				}
				return unsafe { tos(&req.buffer[vs], ve - vs) }
			}
		}
		i = le + 1
	}
	return ''
}

fn accepts_gzip(req fasthttp.HttpRequest) bool {
	return header_val(req, 'accept-encoding').contains('gzip')
}

// body_int parses the request body as an integer, decoding a chunked body first
// when Transfer-Encoding: chunked is set.
fn body_int(req fasthttp.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	if header_val(req, 'transfer-encoding').contains('chunked') {
		return dechunk(req.buffer, req.body.start, req.body.len).bytestr().i64()
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	return raw.i64()
}

// dechunk reassembles the chunked body region buf[start..start+length] into its
// raw bytes: read each chunk-size line, copy that many data bytes, drop the
// framing, and stop at the terminating 0-size chunk or any malformation. Bytes
// in, bytes out — a body of arbitrary binary passes through unchanged.
@[direct_array_access]
fn dechunk(buf []u8, start int, length int) []u8 {
	end := start + length
	mut body := []u8{cap: length}
	mut i := start
	for i < end {
		// the CRLF that ends the chunk-size line
		mut nl := -1
		for j := i; j + 1 < end; j++ {
			if buf[j] == `\r` && buf[j + 1] == `\n` {
				nl = j
				break
			}
		}
		if nl < 0 {
			break
		}
		size := hex_int(buf, i, nl - i)
		if size <= 0 {
			break
		}
		data_start := nl + 2
		// `data_start + size` is computed in i32 and would WRAP negative for a
		// chunk size near 0x7fffffff, slipping past a naive bound check; compare
		// the other way, where both sides stay small and non-negative.
		if size > end - data_start {
			break
		}
		unsafe { body.push_many(&buf[data_start], size) }
		i = data_start + size + 2 // past the data and its trailing CRLF
	}
	return body
}

// hex_int reads a hex integer from buf[start..start+length], stopping at the
// first non-hex byte (a chunk extension's `;`, or the CRLF).
@[direct_array_access]
fn hex_int(buf []u8, start int, length int) int {
	mut n := i64(0)
	for k in start .. start + length {
		c := buf[k]
		d := if c >= `0` && c <= `9` {
			i64(c - `0`)
		} else if c >= `a` && c <= `f` {
			i64(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			i64(c - `A` + 10)
		} else {
			break
		}
		n = n * 16 + d
		if n > 0x7fff_ffff {
			return 0x7fff_ffff // saturate: the caller's bound check then rejects it
		}
	}
	return int(n)
}

// parse_u_at reads a non-negative integer from `s` starting at byte `start`,
// stopping at the first non-digit — no substring allocation.
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

// content_type_for maps a file extension to a response Content-Type.
fn content_type_for(ext string) string {
	return match ext {
		'.css' { 'text/css' }
		'.js' { 'application/javascript' }
		'.html' { 'text/html; charset=utf-8' }
		'.json' { 'application/json' }
		'.svg' { 'image/svg+xml' }
		'.webp' { 'image/webp' }
		'.woff2' { 'font/woff2' }
		'.woff' { 'font/woff' }
		'.png' { 'image/png' }
		'.ico' { 'image/x-icon' }
		'.txt' { 'text/plain' }
		else { 'application/octet-stream' }
	}
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
	// max_idle_conns MUST equal max_open_conns so released conns are not physically
	// closed and re-handshaked on the next acquire (see db.pg's default idle of 2).
	mut db := pg.connect(parse_db_url(url), pg.PoolConfig{ max_open_conns: size, max_idle_conns: size })!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset := json2.decode[[]DatasetItem](os.read_file(dataset_path) or { '[]' }) or {
		[]DatasetItem{}
	}
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json2.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	// Preload the static assets: name -> (disk path, Content-Type, size). The body
	// is streamed with sendfile(2) at request time (ResponseControl.file_path), so
	// only the metadata is kept in memory. Precompressed .br/.gz/.zst siblings are
	// skipped (served identity via sendfile).
	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	mut statics := map[string]StaticFile{}
	for f in (os.ls(static_dir) or { [] }) {
		if f.ends_with('.gz') || f.ends_with('.br') || f.ends_with('.zst') {
			continue
		}
		full := os.join_path(static_dir, f)
		if !os.is_file(full) {
			continue
		}
		statics[f] = StaticFile{
			path:  full
			ctype: content_type_for(os.file_ext(f))
			size:  i64(os.file_size(full))
		}
	}

	mut sh := &Shared{
		db:       db
		dataset:  dataset
		prefixes: prefixes
		statics:  statics
		crud:     map[int]string{}
		crud_mu:  sync.new_rwmutex()
		gz:       map[u64]string{}
		gz_mu:    sync.new_rwmutex()
	}

	mut server := fasthttp.new_server(fasthttp.ServerConfig{
		port:                    8080
		append_handler:          handle
		user_data:               sh
		max_request_buffer_size: 64 * 1024
		make_state:              fn () voidptr {
			return &WorkerCtx{
				scratch: []u8{cap: 64 * 1024}
			}
		}
	})!
	server.run()!
}
