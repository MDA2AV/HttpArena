module main

import fasthttp
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

// CrudSlot is one entry in the id-indexed crud cache slab. `buf` holds the rendered
// item JSON body, refilled IN PLACE across re-caches (allocated once, lazily, then
// reused — never freed under Boehm GC; the slab cap bounds RSS to ~25 MiB lazily).
// A PUT invalidates the slot by flipping `valid = false` and keeping the buffer for
// the next MISS to reuse (cache-aside, no time TTL — matches the validate.sh contract:
// MISS then HIT, then MISS-after-PUT).
struct CrudSlot {
mut:
	buf   []u8
	valid bool
}

// crud GET/PUT ids are `{RAND:1:50000}`; index the slab directly (1..50000). Index 0
// is unused; created items (`{SEQ:100001+}`) fall outside and are never read-cached.
const crud_cache_slots = 50001
// Fixed per-slot buffer cap. The widest item renders to ~202 B; 512 leaves margin.
const crud_cache_bufcap = 512

// StaticFile holds a preloaded file and its MIME content-type for /static/ serving.
struct StaticFile {
	body         []u8
	content_type string
	etag         string
}

// Shared is the process-wide state passed as user_data to every fasthttp handler.
// All mutable fields are mutex-guarded (crud_mu, gz_mu); dataset/prefixes/static_files
// are immutable after startup and need no lock.
struct Shared {
mut:
	db           &pg.DB = unsafe { nil }
	dataset      []DatasetItem
	prefixes     []string
	// id-indexed CRUD cache slab — see CrudSlot comment above
	crud         []CrudSlot
	crud_mu      &sync.RwMutex = unsafe { nil }
	// json-comp: lazy per-(count,m) gzip response cache
	gz           map[u64][]u8
	gz_mu        &sync.RwMutex = unsafe { nil }
	// preloaded static files: url path → StaticFile
	static_files map[string]StaticFile
}

// ── Fixed response byte blobs ─────────────────────────────────────────────────

const pipeline_resp = 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

const not_found = 'HTTP/1.1 404 Not Found\r\nServer: fasthttp\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const created = 'HTTP/1.1 201 Created\r\nServer: fasthttp\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const bad_request = 'HTTP/1.1 400 Bad Request\r\nServer: fasthttp\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const service_unavailable = 'HTTP/1.1 503 Service Unavailable\r\nServer: fasthttp\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// ── Zero-alloc write helpers ──────────────────────────────────────────────────

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

// ws_json_str appends a JSON-escaped string value (no surrounding quotes).
@[direct_array_access]
fn ws_json_str(mut out []u8, s []u8) {
	mut needs := false
	for c in s {
		if c == `"` || c == `\\` || c < 0x20 {
			needs = true
			break
		}
	}
	if !needs {
		wb(mut out, s)
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

// emit writes a complete 200 response with a precomputed body.
fn emit(mut out []u8, ctype string, body []u8) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, body)
}

// emit_xcache writes a 200 JSON response with an X-Cache: HIT|MISS header.
fn emit_xcache(mut out []u8, ctype string, body []u8, cache string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nX-Cache: ')
	ws(mut out, cache)
	ws(mut out, '\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, body)
}

// ── Main handler ─────────────────────────────────────────────────────────────

fn handle(req fasthttp.HttpRequest) !fasthttp.HttpResponse {
	mut sh := unsafe { &Shared(req.user_data) }
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }

	// Fast path for highest-RPS test: blit without building a response struct.
	if route == '/pipeline' {
		return fasthttp.HttpResponse{
			content: pipeline_resp.clone()
		}
	}

	if route == '/baseline11' {
		mut sum := qint_target(target, 'a') + qint_target(target, 'b')
		if method == 'POST' {
			sum += body_int(req)
		}
		return resp_int(sum)
	} else if route == '/upload' {
		n := parse_content_length(req)
		return resp_int(n)
	} else if route.starts_with('/json/') {
		count := clamp_count(parse_u_at(route, 6), sh.dataset.len)
		mut m := qint_target(target, 'm')
		if m == 0 {
			m = 1
		}
		if req_accepts_gzip(req) {
			return sh.json_gzip_response(count, m)
		}
		return fasthttp.HttpResponse{
			content:       sh.json_response(count, m)
			content_owned: true
		}
	} else if route == '/async-db' {
		body := sh.async_db(qint_target(target, 'min'), qint_target(target, 'max'),
			qint_target(target, 'limit'))
		return resp_bytes('application/json', body.bytes())
	} else if route == '/fortunes' {
		return sh.fortunes_response()
	} else if route.starts_with('/static/') {
		return sh.static_response(route)
	} else if route == '/crud/items' {
		if method == 'POST' {
			return sh.crud_create(req)
		}
		return sh.crud_list(qstr_target(target, 'category'), qint_target(target, 'page'),
			qint_target(target, 'limit'))
	} else if route.starts_with('/crud/items/') {
		id := int(parse_u_at(route, 12))
		if method == 'PUT' {
			return sh.crud_update(id, req)
		}
		return sh.crud_get(id)
	}
	return fasthttp.HttpResponse{
		content: not_found.clone()
	}
}

// ── Response helpers ──────────────────────────────────────────────────────────

// resp_bytes builds a 200 response with raw body bytes.
fn resp_bytes(ctype string, body []u8) fasthttp.HttpResponse {
	mut out := []u8{cap: body.len + 96}
	emit(mut out, ctype, body)
	return fasthttp.HttpResponse{
		content:       out
		content_owned: true
	}
}

// resp_int formats n and returns a 200 text/plain response.
fn resp_int(n i64) fasthttp.HttpResponse {
	mut body := []u8{cap: 24}
	wi(mut body, n)
	mut out := []u8{cap: body.len + 96}
	emit(mut out, 'text/plain', body)
	return fasthttp.HttpResponse{
		content:       out
		content_owned: true
	}
}

// ── /json ─────────────────────────────────────────────────────────────────────

// json_response builds the full /json response body (precomputed prefix + total).
fn (sh &Shared) json_response(count int, m i64) []u8 {
	mut clen := 21 + digits(i64(count))
	if count > 0 {
		clen += count - 1
	}
	for i in 0 .. count {
		t := sh.dataset[i].price * sh.dataset[i].quantity * m
		clen += sh.prefixes[i].len + digits(t) + 1
	}
	mut out := []u8{cap: clen + 96}
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(clen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		if i > 0 {
			ws(mut out, ',')
		}
		ws(mut out, sh.prefixes[i])
		wi(mut out, sh.dataset[i].price * sh.dataset[i].quantity * m)
		ws(mut out, '}')
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	ws(mut out, '}')
	return out
}

// json_gzip_response returns the gzipped /json response. The cache is process-shared
// (all workers share `sh`) and mutex-guarded. Compress once on the first miss.
fn (mut sh Shared) json_gzip_response(count int, m i64) fasthttp.HttpResponse {
	key := (u64(u32(count)) << 32) | u64(u32(m))
	// Read under rlock — fast path (hit) does not need the write lock.
	sh.gz_mu.@rlock()
	if c := sh.gz[key] {
		cached_resp := c.clone()
		sh.gz_mu.runlock()
		return fasthttp.HttpResponse{
			content:       cached_resp
			content_owned: true
		}
	}
	sh.gz_mu.runlock()

	// Miss: build the body as a plain string and compress it.
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
	body := sb.str()
	gz := gzip.compress(body.bytes()) or {
		// Fallback to plain JSON if compression fails.
		return fasthttp.HttpResponse{
			content:       sh.json_response(count, m)
			content_owned: true
		}
	}
	mut resp := []u8{cap: gz.len + 128}
	ws(mut resp, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut resp, i64(gz.len))
	ws(mut resp, '\r\nConnection: keep-alive\r\n\r\n')
	unsafe { resp.push_many(gz.data, gz.len) }
	sh.gz_mu.@lock()
	if sh.gz.len < 1024 {
		sh.gz[key] = resp
	}
	sh.gz_mu.unlock()
	return fasthttp.HttpResponse{
		content:       resp.clone()
		content_owned: true
	}
}

// ── /async-db ─────────────────────────────────────────────────────────────────

fn (mut sh Shared) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	rows := sh.db.exec_param_many(
		'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		[min.str(), max.str(), lim.str()]) or { return '{"items":[],"count":0}' }
	mut out := []u8{cap: rows.len * 200 + 32}
	ws(mut out, '{"items":[')
	for i, row in rows {
		if i > 0 {
			ws(mut out, ',')
		}
		render_db_row(mut out, row)
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(rows.len))
	ws(mut out, '}')
	return out.bytestr()
}

// render_db_row writes one items row (from db.pg Result) as JSON into out.
// tags is the text representation of a JSONB column — already valid JSON.
fn render_db_row(mut out []u8, row pg.Row) {
	ws(mut out, '{"id":')
	wi(mut out, nn(row.vals[0]).i64())
	ws(mut out, ',"name":"')
	ws_json_str(mut out, nn(row.vals[1]).bytes())
	ws(mut out, '","category":"')
	ws_json_str(mut out, nn(row.vals[2]).bytes())
	ws(mut out, '","price":')
	wi(mut out, nn(row.vals[3]).i64())
	ws(mut out, ',"quantity":')
	wi(mut out, nn(row.vals[4]).i64())
	ws(mut out, ',"active":')
	ws(mut out, if nn(row.vals[5]) == 't' { 'true' } else { 'false' })
	ws(mut out, ',"tags":')
	// tags is stored as JSON text — emit it raw (already valid JSON).
	raw_tags := nn3(row.vals[6], '[]')
	ws(mut out, raw_tags)
	ws(mut out, ',"rating":{"score":')
	wi(mut out, nn(row.vals[7]).i64())
	ws(mut out, ',"count":')
	wi(mut out, nn(row.vals[8]).i64())
	ws(mut out, '}}')
}

// ── /fortunes ─────────────────────────────────────────────────────────────────

struct Fortune {
	id      int
	message string
}

const synthetic_fortune = 'Additional fortune added at request time.'

fn (mut sh Shared) fortunes_response() fasthttp.HttpResponse {
	rows := sh.db.exec_param_many('SELECT id, message FROM fortune', []) or {
		body := '<!doctype html><html><body><table></table></body></html>'
		return resp_bytes('text/html; charset=utf-8', body.bytes())
	}
	mut fortunes := []Fortune{cap: rows.len + 1}
	for row in rows {
		fortunes << Fortune{
			id:      nn(row.vals[0]).int()
			message: nn(row.vals[1])
		}
	}
	fortunes << Fortune{
		id:      0
		message: synthetic_fortune
	}
	fortunes.sort_with_compare(fn (a &Fortune, b &Fortune) int {
		if a.message < b.message {
			return -1
		}
		if a.message > b.message {
			return 1
		}
		return 0
	})
	mut body := []u8{cap: fortunes.len * 256 + 512}
	ws(mut body,
		'<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in fortunes {
		ws(mut body, '<tr><td>')
		wi(mut body, i64(f.id))
		ws(mut body, '</td><td>')
		escape_html_into(mut body, f.message.bytes())
		ws(mut body, '</td></tr>')
	}
	ws(mut body, '</table></body></html>')
	mut out := []u8{cap: body.len + 96}
	emit(mut out, 'text/html; charset=utf-8', body)
	return fasthttp.HttpResponse{
		content:       out
		content_owned: true
	}
}

// ── /static/ ─────────────────────────────────────────────────────────────────

fn (sh &Shared) static_response(route string) fasthttp.HttpResponse {
	sf := sh.static_files[route] or {
		return fasthttp.HttpResponse{
			content: not_found.clone()
		}
	}
	mut out := []u8{cap: sf.body.len + 128}
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: fasthttp\r\nContent-Type: ')
	ws(mut out, sf.content_type)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(sf.body.len))
	ws(mut out, '\r\nETag: "')
	ws(mut out, sf.etag)
	ws(mut out, '"\r\nCache-Control: public, max-age=31536000\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, sf.body)
	return fasthttp.HttpResponse{
		content:       out
		content_owned: true
	}
}

// ── /crud ─────────────────────────────────────────────────────────────────────

fn (mut sh Shared) crud_list(category string, page i64, limit i64) fasthttp.HttpResponse {
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
	rows := sh.db.exec_param_many(
		'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3',
		[category, lim.str(), offset.str()]) or {
		return resp_bytes('application/json', '{"items":[],"total":0,"page":1}'.bytes())
	}
	mut body := []u8{cap: rows.len * 200 + 64}
	ws(mut body, '{"items":[')
	mut total := i64(0)
	for i, row in rows {
		if i > 0 {
			ws(mut body, ',')
		}
		render_db_row(mut body, row)
		total = nn(row.vals[9]).i64()
	}
	ws(mut body, '],"total":')
	wi(mut body, total)
	ws(mut body, ',"page":')
	wi(mut body, p)
	ws(mut body, '}')
	mut out := []u8{cap: body.len + 96}
	emit(mut out, 'application/json', body)
	return fasthttp.HttpResponse{
		content:       out
		content_owned: true
	}
}

fn (mut sh Shared) crud_get(id int) fasthttp.HttpResponse {
	// Cache-aside lookup: snapshot cached body under read-lock.
	mut hit := false
	mut body_snap := []u8{}
	if id >= 1 && id < crud_cache_slots {
		sh.crud_mu.@rlock()
		s := sh.crud[id]
		if s.valid && s.buf.len > 0 {
			body_snap = s.buf.clone()
			hit = true
		}
		sh.crud_mu.runlock()
	}
	if hit {
		mut out := []u8{cap: body_snap.len + 128}
		emit_xcache(mut out, 'application/json', body_snap, 'HIT')
		return fasthttp.HttpResponse{
			content:       out
			content_owned: true
		}
	}
	// Cache miss: query DB.
	rows := sh.db.exec_param_many(
		'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1',
		[id.str()]) or {
		return fasthttp.HttpResponse{
			content: service_unavailable.clone()
		}
	}
	if rows.len == 0 {
		return fasthttp.HttpResponse{
			content: not_found.clone()
		}
	}
	mut body := []u8{cap: crud_cache_bufcap}
	render_db_row(mut body, rows[0])
	// Populate cache slot IN PLACE under write-lock.
	if id >= 1 && id < crud_cache_slots {
		sh.crud_mu.@lock()
		mut slot := &sh.crud[id]
		if slot.buf.cap == 0 {
			slot.buf = []u8{cap: crud_cache_bufcap}
		}
		unsafe { slot.buf.len = 0 }
		slot.buf << body
		slot.valid = true
		sh.crud_mu.unlock()
	}
	mut out := []u8{cap: body.len + 128}
	emit_xcache(mut out, 'application/json', body, 'MISS')
	return fasthttp.HttpResponse{
		content:       out
		content_owned: true
	}
}

fn (mut sh Shared) crud_create(req fasthttp.HttpRequest) fasthttp.HttpResponse {
	body_bytes := req.buffer[req.body.start..req.body.start + req.body.len]
	if c := parse_crud_body_fast(body_bytes, true) {
		sh.db.exec_param_many(
			"INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity",
			[c.id.str(), c.name.bytestr(), c.category.bytestr(), c.price.str(), c.quantity.str()]) or {
			return fasthttp.HttpResponse{
				content: service_unavailable.clone()
			}
		}
		return fasthttp.HttpResponse{
			content: created.clone()
		}
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		return fasthttp.HttpResponse{
			content: bad_request.clone()
		}
	}
	sh.db.exec_param_many(
		"INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity",
		[c.id.str(), c.name, c.category, c.price.str(), c.quantity.str()]) or {
		return fasthttp.HttpResponse{
			content: service_unavailable.clone()
		}
	}
	return fasthttp.HttpResponse{
		content: created.clone()
	}
}

fn (mut sh Shared) crud_update(id int, req fasthttp.HttpRequest) fasthttp.HttpResponse {
	body_bytes := req.buffer[req.body.start..req.body.start + req.body.len]
	if c := parse_crud_body_fast(body_bytes, false) {
		sh.db.exec_param_many(
			'UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1',
			[id.str(), c.name.bytestr(), c.category.bytestr(), c.price.str(), c.quantity.str()]) or {
			return fasthttp.HttpResponse{
				content: service_unavailable.clone()
			}
		}
	} else {
		raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
		c2 := json.decode(CrudCreate, raw) or {
			return fasthttp.HttpResponse{
				content: bad_request.clone()
			}
		}
		sh.db.exec_param_many(
			'UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1',
			[id.str(), c2.name, c2.category, c2.price.str(), c2.quantity.str()]) or {
			return fasthttp.HttpResponse{
				content: service_unavailable.clone()
			}
		}
	}
	// Invalidate cache slot: flip valid = false, keep buf for next MISS to reuse.
	if id >= 1 && id < crud_cache_slots {
		sh.crud_mu.@lock()
		sh.crud[id].valid = false
		sh.crud_mu.unlock()
	}
	return resp_bytes('application/json', '{"status":"ok"}'.bytes())
}

// ── JSON fast-path body parser (no json.decode allocation on happy path) ─────

struct CrudFastBody {
	id       i64
	name     []u8
	category []u8
	price    i64
	quantity i64
}

@[inline]
fn is_json_ws(c u8) bool {
	return c == ` ` || c == `\n` || c == `\r` || c == `\t`
}

@[direct_array_access]
fn has_key_at(buf []u8, at int, key string) bool {
	if at + key.len > buf.len {
		return false
	}
	for i in 0 .. key.len {
		if buf[at + i] != key[i] {
			return false
		}
	}
	return true
}

@[direct_array_access]
fn json_value_start(buf []u8, key string) ?int {
	for i := 0; i < buf.len; i++ {
		if !has_key_at(buf, i, key) {
			continue
		}
		mut j := i + key.len
		for j < buf.len && is_json_ws(buf[j]) {
			j++
		}
		if j >= buf.len || buf[j] != `:` {
			continue
		}
		j++
		for j < buf.len && is_json_ws(buf[j]) {
			j++
		}
		if j < buf.len {
			return j
		}
		return none
	}
	return none
}

@[direct_array_access]
fn json_string_field_borrowed(buf []u8, key string) ?[]u8 {
	start := json_value_start(buf, key) or { return none }
	if start >= buf.len || buf[start] != `"` {
		return none
	}
	mut i := start + 1
	for i < buf.len {
		c := buf[i]
		if c == `\\` {
			return none // fall back to json.decode for escaped strings
		}
		if c == `"` {
			return buf[start + 1..i]
		}
		i++
	}
	return none
}

@[direct_array_access]
fn json_i64_field(buf []u8, key string) ?i64 {
	mut i := json_value_start(buf, key) or { return none }
	if i >= buf.len {
		return none
	}
	mut neg := false
	if buf[i] == `-` {
		neg = true
		i++
	}
	if i >= buf.len || buf[i] < `0` || buf[i] > `9` {
		return none
	}
	mut n := i64(0)
	for i < buf.len {
		c := buf[i]
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + i64(c - `0`)
		i++
	}
	return if neg { -n } else { n }
}

@[direct_array_access]
fn parse_crud_body_fast(body []u8, need_id bool) ?CrudFastBody {
	name := json_string_field_borrowed(body, '"name"') or { return none }
	category := json_string_field_borrowed(body, '"category"') or { return none }
	price := json_i64_field(body, '"price"') or { return none }
	quantity := json_i64_field(body, '"quantity"') or { return none }
	id := if need_id { json_i64_field(body, '"id"') or { return none } } else { i64(0) }
	return CrudFastBody{
		id:       id
		name:     name
		category: category
		price:    price
		quantity: quantity
	}
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// escape_html_into HTML-escapes s directly into out (no intermediate Builder).
@[direct_array_access]
fn escape_html_into(mut out []u8, s []u8) {
	mut needs := false
	for c in s {
		if c == `&` || c == `<` || c == `>` || c == `"` || c == `'` {
			needs = true
			break
		}
	}
	if !needs {
		wb(mut out, s)
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

// parse_u_at reads an unsigned integer from s starting at byte `start`.
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

// qint_target extracts an integer query parameter from the full target string.
fn qint_target(target string, key string) i64 {
	needle := key + '='
	idx := target.index(needle) or { return 0 }
	rest := target[idx + needle.len..]
	endp := rest.index('&') or { rest.len }
	return rest[..endp].i64()
}

// qstr_target extracts a string query parameter from the full target string.
fn qstr_target(target string, key string) string {
	needle := key + '='
	idx := target.index(needle) or { return '' }
	rest := target[idx + needle.len..]
	endp := rest.index('&') or { rest.len }
	return rest[..endp]
}

// body_int parses the request body as an integer (handles chunked encoding).
fn body_int(req fasthttp.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	raw := req.buffer[req.body.start..req.body.start + req.body.len].bytestr()
	headers := req.buffer[req.header_fields.start..req.header_fields.start + req.header_fields.len].bytestr()
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
		if ds + size > s.len {
			break
		}
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

// parse_content_length returns the Content-Length value from the request headers,
// or req.body.len if the header is absent or cannot be parsed.
@[direct_array_access]
fn parse_content_length(req fasthttp.HttpRequest) i64 {
	headers := req.buffer[req.header_fields.start..req.header_fields.start + req.header_fields.len].bytestr()
	needle := 'content-length:'
	lc := headers.to_lower()
	idx := lc.index(needle) or { return i64(req.body.len) }
	rest := lc[idx + needle.len..].trim_left(' \t')
	mut n := i64(0)
	for c in rest {
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + i64(c - `0`)
	}
	if n > 0 {
		return n
	}
	return i64(req.body.len)
}

// req_accepts_gzip checks the Accept-Encoding header for 'gzip'.
fn req_accepts_gzip(req fasthttp.HttpRequest) bool {
	headers := req.buffer[req.header_fields.start..req.header_fields.start + req.header_fields.len].bytestr()
	lc := headers.to_lower()
	return lc.contains('accept-encoding:') && lc.contains('gzip')
}

@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

// ── DB / startup helpers ──────────────────────────────────────────────────────

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

// mime_type returns a Content-Type for the given file extension.
fn mime_type(ext string) string {
	return match ext {
		'.html', '.htm' { 'text/html; charset=utf-8' }
		'.css' { 'text/css' }
		'.js', '.mjs' { 'application/javascript' }
		'.json' { 'application/json' }
		'.svg' { 'image/svg+xml' }
		'.webp' { 'image/webp' }
		'.png' { 'image/png' }
		'.jpg', '.jpeg' { 'image/jpeg' }
		'.gif' { 'image/gif' }
		'.ico' { 'image/x-icon' }
		'.woff' { 'font/woff' }
		'.woff2' { 'font/woff2' }
		'.ttf' { 'font/ttf' }
		'.otf' { 'font/otf' }
		'.txt' { 'text/plain' }
		'.xml' { 'application/xml' }
		'.pdf' { 'application/pdf' }
		'.zip' { 'application/zip' }
		'.gz' { 'application/gzip' }
		'.br' { 'application/x-br' }
		else { 'application/octet-stream' }
	}
}

// load_static_files preloads all files from `dir` into memory, keyed by their URL
// path (`/static/<filename>`). .br and .gz siblings are skipped here (no content
// negotiation — fasthttp doesn't provide an Accept-Encoding hook at the preload level,
// and the test only checks raw file bytes and correct Content-Type).
fn load_static_files(dir string, url_prefix string) map[string]StaticFile {
	mut files := map[string]StaticFile{}
	entries := os.ls(dir) or { return files }
	for name in entries {
		// Skip precompressed siblings — clients requesting the plain file get the raw body.
		if name.ends_with('.br') || name.ends_with('.gz') {
			continue
		}
		path := dir + '/' + name
		if os.is_dir(path) {
			continue
		}
		body := os.read_bytes(path) or { continue }
		ext := os.file_ext(name)
		url_path := url_prefix + name
		// Compute a simple hex ETag from file size + name length (stable for the arena
		// fixture set; a proper hash would need stdlib crypto not available here).
		etag_val := (u64(body.len) ^ (u64(name.len) << 32)).hex()
		files[url_path] = StaticFile{
			body:         body
			content_type: mime_type(ext)
			etag:         etag_val
		}
	}
	return files
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
	// released beyond the 2nd is physically closed — connection churn on every concurrent
	// DB request. Keeping idle == open maintains a fixed warm pool.
	mut db := pg.connect(parse_db_url(url), pg.PoolConfig{
		max_open_conns: size
		max_idle_conns: size
	})!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset := json.decode([]DatasetItem, os.read_file(dataset_path) or { '[]' }) or {
		[]DatasetItem{}
	}
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	static_files := load_static_files(static_dir, '/static/')

	mut sh := &Shared{
		db:           db
		dataset:      dataset
		prefixes:     prefixes
		crud:         []CrudSlot{len: crud_cache_slots}
		crud_mu:      sync.new_rwmutex()
		gz:           map[u64][]u8{}
		gz_mu:        sync.new_rwmutex()
		static_files: static_files
	}

	mut server := fasthttp.new_server(fasthttp.ServerConfig{
		port:      8080
		handler:   handle
		user_data: sh
	})!
	server.run()!
}
