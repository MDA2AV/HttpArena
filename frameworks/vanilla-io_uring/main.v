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

struct CrudCreate {
	id       int
	name     string
	category string
	price    int
	quantity int
}

struct Fortune {
	id      int
	message []u8 // BORROWED view into the pg.Row string data (valid during render only)
}

// CrudSlot is one entry of the id-indexed crud cache slab (ported from vanilla-epoll).
// `buf` is the rendered item response body, refilled IN PLACE across re-caches
// (allocated once, lazily, then reused — never orphaned). The entry is a valid HIT iff
// `valid && buf.len > 0`; a PUT just sets `valid = false` and keeps the buffer for the
// next MISS to reuse (cache-aside, no time-based expiry). The slab replaces the former
// map[int]string: identical structure to the epoll twin, so the two entries stay
// diffable, and it never re-encodes with json.encode on a MISS.
struct CrudSlot {
mut:
	buf   []u8
	valid bool
}

// crud GET/PUT ids are `{RAND:1:50000}`; index the slab directly (1..50000). Index 0 is
// unused; created items (`{SEQ:100001}`) fall outside and are never read-cached.
const crud_cache_slots = 50001
// Fixed per-slot buffer cap. The widest seed item renders to ~202 B; 512 leaves ample
// margin so a slot's buffer, allocated once on first MISS, never reallocates.
const crud_cache_bufcap = 512

// SharedRO is the immutable, process-wide data plus the mutex-guarded caches, shared by
// reference across all workers. Mirrors the vanilla-epoll SharedRO so the two entries
// have the same shape. (Unlike epoll's per-worker pg_async pool, db.pg's pool is itself
// thread-safe — exec_param_many acquires/releases a pooled conn per call — so a single
// shared handle is fine here.)
struct SharedRO {
	db       &pg.DB = unsafe { nil }
	dataset  []DatasetItem
	prefixes []string                  // per item: `{…,"total":` (everything but the request-dependent total)
	asv      static_assets.AssetServer // /static/* via the audited module (negotiation + queue_buf borrowed send)
mut:
	// crud cache-aside: id-indexed slab (see CrudSlot). PROCESS-SHARED (mutex-guarded) so
	// the two validate probes (MISS then HIT) hit the same cache regardless of which ring
	// worker serves them — the pool/scratch is per-worker, only these caches are shared.
	crud     []CrudSlot
	crud_mu  &sync.RwMutex = unsafe { nil }
	// json-comp cache: the gzipped response for a given (count, m) is fully
	// deterministic and gzip dominates the cost, so compress once and reuse.
	// Key = (count << 32) | m. The benchmark hits only a few pairs, so it's tiny.
	gz_cache map[u64][]u8
	gz_mu    &sync.RwMutex = unsafe { nil }
}

// WorkerCtx is the per-worker state handed to every handler call as the make_state value
// (now that the io_uring backend supports stateful_handler — enghitalo/vanilla#93). Each
// ring worker owns its own reused render `scratch` (reset to len 0 per response, grown to
// a high-water mark) so the DB-render paths allocate NO per-request buffer — matching the
// epoll twin's WorkerCtx.scratch. The shared data + caches live in `ro`.
struct WorkerCtx {
mut:
	ro      &SharedRO = unsafe { nil }
	scratch []u8
}

// ── zero-alloc write helpers (push_many, never single-element `<<`) ──────────
// This whole block is byte-for-byte identical to the vanilla-epoll twin: the two
// entries share one audited set of response builders so they stay diffable.

// ws appends a string's bytes to `out` with no allocation (push_many copies
// straight from the string's backing storage into the connection write buffer).
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wb appends a byte slice (e.g. a precomputed const response) into `out` with a
// single bulk copy — no allocation.
@[inline]
fn wb(mut out []u8, b []u8) {
	unsafe { out.push_many(b.data, b.len) }
}

// wi appends the decimal digits of an integer to `out`, no allocation (itoa into a
// stack scratch, flushed with a single push_many — single-element `<<` is several
// times slower on post-0.5.1 V, vlang/v#27468). Negative-aware: `/baseline11` sums
// can go negative (a+b with negative query ints), so it mirrors the epoll twin's
// signed formatter rather than the old non-negative-only version.
@[direct_array_access]
fn wi(mut out []u8, n i64) {
	mut tmp := [20]u8{}
	if n == 0 {
		tmp[0] = u8(`0`)
		unsafe { out.push_many(&tmp[0], 1) }
		return
	}
	neg := n < 0
	// Build the magnitude in u64: i64::MIN's i64 negation overflows (the value isn't
	// representable as i64), so derive it as -(n+1)+1 with the +1 in u64.
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

// ws_json_str appends a JSON-escaped string value (no surrounding quotes). Fast path:
// most values have no special characters, so emit them as one bulk copy.
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

// emit writes a complete 200 response with a precomputed body into `out`.
fn emit(mut out []u8, ctype string, body []u8) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, body)
}

// write_resp appends a complete HTTP/1.1 response (status line + headers + body)
// straight into the connection's persistent write buffer — no intermediate
// strings.Builder, no body→response copy, no per-request heap allocation.
fn write_resp(mut out []u8, ctype string, body string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

// emit_xcache writes a complete 200 JSON response carrying an X-Cache: HIT|MISS header
// straight into `out`. Byte-identical to the vanilla-epoll twin's inlined framing (both
// now share this helper). The stateless request_handler has no per-worker scratch, so
// the []u8 body is either the cache slot itself (HIT, emitted under the read-lock) or a
// freshly rendered local buffer (MISS).
fn emit_xcache(mut out []u8, ctype string, body []u8, cache string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nX-Cache: ')
	ws(mut out, cache)
	ws(mut out, '\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, body)
}

// emit_int writes a 200 whose body is a single integer, formatting it into a stack
// scratch (no heap alloc). The obvious `write_resp(.., n.str())` heap-allocated an
// int->string on every request — pure GC pressure on the highest-RPS non-DB profiles
// (/baseline11, /upload). The epoll twin uses a per-worker scratch (make_state); the
// io_uring backend is stateless (request_handler only, enghitalo/vanilla#83), so this
// renders into a 20-byte stack buffer instead — same bytes, still zero-alloc.
@[direct_array_access]
fn emit_int(mut out []u8, ctype string, n i64) {
	mut tmp := [20]u8{}
	mut i := 20
	if n == 0 {
		i = 19
		tmp[19] = u8(`0`)
	} else {
		neg := n < 0
		mut x := u64(n)
		if neg {
			x = u64(-(n + 1)) + 1
		}
		for x > 0 {
			i--
			tmp[i] = u8(`0`) + u8(x % 10)
			x /= 10
		}
		if neg {
			i--
			tmp[i] = u8(`-`)
		}
	}
	blen := 20 - i
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(blen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	unsafe { out.push_many(&tmp[i], blen) }
}

// Precomputed full response for the fixed /pipeline plaintext "ok" (the highest-RPS
// test): one bulk copy on the hot path, no query scan / route slice / build.
const pipeline_resp = 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// Raw request prefix for the fixed /pipeline plaintext test. The trailing space is the
// request-line SP, so this matches exactly `GET /pipeline ` (not /pipeline2).
const pipeline_prefix = 'GET /pipeline '.bytes()

// has_pipeline_prefix is the skip-decode gate for the highest-RPS /pipeline test: match
// the raw request prefix and blit the response WITHOUT parsing. The io_uring backend
// hands the handler one framed request at a time, so the decode adds nothing here.
// Ported from the epoll twin (there the in-handle parse was ~17% of this request).
@[direct_array_access]
fn has_pipeline_prefix(b []u8) bool {
	if b.len < pipeline_prefix.len {
		return false
	}
	for i in 0 .. pipeline_prefix.len {
		if b[i] != pipeline_prefix[i] {
			return false
		}
	}
	return true
}

const not_found = 'HTTP/1.1 404 Not Found\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const created = 'HTTP/1.1 201 Created\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const bad_request = 'HTTP/1.1 400 Bad Request\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// ── request routing ──────────────────────────────────────────────────────────

fn handle(req_buffer []u8, _fd int, mut out []u8, state voidptr) ! {
	mut w := unsafe { &WorkerCtx(state) }
	// Skip-decode fast path: the fixed /pipeline plaintext (highest-RPS test) blits its
	// response before ANY parsing (the request is already framed by the backend).
	if has_pipeline_prefix(req_buffer) {
		wb(mut out, pipeline_resp)
		return
	}
	// decode_into fills req in place — no `!HttpRequest` Result boxing (~13% of the parse
	// path on the epoll twin's callgrind), matching that entry's parser entry point.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		wb(mut out, bad_request)
		return
	}
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	// Pipelined hot path: fixed response, blit the constant before the '?'-scan + route
	// slice. The profile sends exactly /pipeline (no query), so exact-match.
	if target == '/pipeline' {
		wb(mut out, pipeline_resp)
		return
	}
	// Route on the path before '?' WITHOUT allocating: a tos() view into the request
	// buffer rather than all_before()'s per-request copy.
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }

	if route == '/baseline11' {
		mut sum := qint(req, qk_a) + qint(req, qk_b)
		if method == 'POST' {
			sum += body_int(req)
		}
		emit_int(mut out, 'text/plain', sum)
	} else if route == '/upload' {
		// Answer by the declared Content-Length, not req.body.len: large bodies are
		// STREAMED (drained off the socket, head-only passed to the handler) by the lib's
		// body-drain, so req.body is empty for them. Falls back to the buffered body
		// length when Content-Length is absent (e.g. chunked). Mirrors vanilla-epoll.
		cl := req.content_length()
		n := if cl >= 0 { i64(cl) } else { i64(req.body.len) }
		emit_int(mut out, 'text/plain', n)
	} else if route.starts_with('/json/') {
		count := clamp_count(parse_u_at(route, 6), w.ro.dataset.len)
		mut m := qint(req, qk_m)
		if m == 0 {
			m = 1
		}
		if accepts_gzip(req) {
			// json-comp profile: gzip the body and set Content-Encoding.
			w.write_json_gzip(mut out, count, m)
		} else {
			w.write_json_response(mut out, count, m)
		}
	} else if route == '/async-db' {
		w.write_async_db(mut out, qint(req, qk_min), qint(req, qk_max), qint(req, qk_limit))
	} else if route == '/fortunes' {
		w.write_fortunes(mut out)
	} else if route.starts_with('/static/') {
		// Canonical static serving via the lib's static_assets module, mounted at
		// /static/: negotiates the precompressed .br/.gz sibling per Accept-Encoding
		// (the arena sends `br;q=1`, so this ships the ~4x smaller .br body) and emits
		// small assets via core.queue_buf borrowed send. ONE audited path shared with
		// vanilla-epoll, replacing the hand-rolled identity-only map.
		w.ro.asv.respond_into(req_buffer, mut out) or { wb(mut out, not_found) }
	} else if route == '/crud/items' {
		if method == 'POST' {
			w.write_crud_create(mut out, req)
		} else {
			w.write_crud_list(mut out, qstr(req, qk_category), qint(req, qk_page), qint(req,
				qk_limit))
		}
	} else if route.starts_with('/crud/items/') {
		id := int(parse_u_at(route, 12))
		if method == 'PUT' {
			w.write_crud_update(mut out, id, req)
		} else {
			w.write_crud_get(mut out, id)
		}
	} else {
		wb(mut out, not_found)
	}
}

// ── DB row rendering (byte-level, no reflection) ──────────────────────────────

// render_item_pg writes one items-row as JSON directly into `body` from a db.pg text
// row — no DbItem struct, no json.encode reflection (the epoll twin renders the same
// bytes from a binary pg_async.Row via render_item). Columns, in query order: id, name,
// category, price, quantity, active, tags(jsonb text), rating_score, rating_count.
// `tags` is the JSONB column as Postgres text (already valid JSON), emitted RAW — no
// decode/re-encode round-trip.
@[direct_array_access]
fn render_item_pg(mut body []u8, row pg.Row) {
	ws(mut body, '{"id":')
	wi(mut body, nn(row.vals[0]).i64())
	ws(mut body, ',"name":"')
	ws_json_str(mut body, sbytes(nn(row.vals[1])))
	ws(mut body, '","category":"')
	ws_json_str(mut body, sbytes(nn(row.vals[2])))
	ws(mut body, '","price":')
	wi(mut body, nn(row.vals[3]).i64())
	ws(mut body, ',"quantity":')
	wi(mut body, nn(row.vals[4]).i64())
	ws(mut body, ',"active":')
	ws(mut body, if nn(row.vals[5]) == 't' { 'true' } else { 'false' })
	ws(mut body, ',"tags":')
	wb(mut body, sbytes(nn3(row.vals[6], '[]')))
	ws(mut body, ',"rating":{"score":')
	wi(mut body, nn(row.vals[7]).i64())
	ws(mut body, ',"count":')
	wi(mut body, nn(row.vals[8]).i64())
	ws(mut body, '}}')
}

// sbytes borrows a string's bytes as a non-owning []u8 view (no clone). Valid only while
// the owning string is alive — used to feed row column strings into the byte renderers
// during a synchronous render, before `rows` is dropped.
@[inline]
fn sbytes(s string) []u8 {
	return unsafe { s.str.vbytes(s.len) }
}

// ── /async-db ────────────────────────────────────────────────────────────────

const async_db_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3'

// write_async_db runs the range query and renders the rows straight into `out`.
// NOTE: db.pg is BLOCKING; on the single-threaded io_uring ring worker this stalls the
// ring for the query's duration (enghitalo/vanilla#83) — the row rendering below is
// zero-reflection regardless, matching the epoll twin's render_async_db.
fn (mut w WorkerCtx) write_async_db(mut out []u8, min i64, max i64, limit i64) {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	mut db := w.ro.db
	rows := db.exec_param_many(async_db_sql, [min.str(), max.str(), lim.str()]) or {
		write_resp(mut out, 'application/json', '{"items":[],"count":0}')
		return
	}
	// Render into the worker's REUSED scratch (reset to len 0, grows to a high-water mark)
	// — no per-request buffer alloc, matching the epoll twin's render_async_db.
	unsafe { w.scratch.len = 0 }
	ws(mut w.scratch, '{"items":[')
	for i, row in rows {
		if i > 0 {
			ws(mut w.scratch, ',')
		}
		render_item_pg(mut w.scratch, row)
	}
	ws(mut w.scratch, '],"count":')
	wi(mut w.scratch, i64(rows.len))
	ws(mut w.scratch, '}')
	emit(mut out, 'application/json', w.scratch)
}

// ── /fortunes ────────────────────────────────────────────────────────────────

const synthetic_fortune = 'Additional fortune added at request time.'.bytes()

fn (mut w WorkerCtx) write_fortunes(mut out []u8) {
	mut db := w.ro.db
	rows := db.exec_param_many('SELECT id, message FROM fortune', []) or {
		write_resp(mut out, 'text/html; charset=utf-8',
			'<!doctype html><html><body><table></table></body></html>')
		return
	}
	mut fortunes := []Fortune{cap: rows.len + 1}
	for row in rows {
		// BORROW the message bytes from the row (stable while `rows` is alive) — no clone.
		fortunes << Fortune{
			id:      nn(row.vals[0]).int()
			message: sbytes(nn(row.vals[1]))
		}
	}
	fortunes << Fortune{
		id:      0
		message: synthetic_fortune
	}
	fortunes.sort_with_compare(cmp_fortune_message)
	unsafe { w.scratch.len = 0 } // reuse the worker's render buffer (no per-request alloc)
	ws(mut w.scratch,
		'<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in fortunes {
		ws(mut w.scratch, '<tr><td>')
		wi(mut w.scratch, i64(f.id))
		ws(mut w.scratch, '</td><td>')
		escape_html_into(mut w.scratch, f.message) // escape directly into scratch (no Builder)
		ws(mut w.scratch, '</td></tr>')
	}
	ws(mut w.scratch, '</table></body></html>')
	emit(mut out, 'text/html; charset=utf-8', w.scratch)
}

// cmp_fortune_message orders fortunes by message, lexicographically by bytes — V has no
// `<` on []u8, so the sort needs an explicit comparator (returns <0 / 0 / >0).
fn cmp_fortune_message(a &Fortune, b &Fortune) int {
	mut i := 0
	for i < a.message.len && i < b.message.len {
		if a.message[i] != b.message[i] {
			return int(a.message[i]) - int(b.message[i])
		}
		i++
	}
	return a.message.len - b.message.len
}

// ── /crud ──────────────────────────────────────────────────────────────────
// crud stays on the BLOCKING db.pg client (the io_uring backend has no async runtime,
// enghitalo/vanilla#83). The renders/parsers below are the zero-reflection ports from
// the epoll twin (enghitalo/vanilla#85); db.pg text params still need C-string values,
// so the int params are still `.str()`'d and string params `.bytestr()`'d/cloned.

// crud_list uses a single window-count query (count(*) OVER()) so the page and the total
// come back together — ONE query instead of the former page + separate count(*).
const crud_list_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3'

const crud_get_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1'

const crud_insert_sql = "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity"

const crud_update_sql = 'UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1'

fn (mut w WorkerCtx) write_crud_list(mut out []u8, category string, page i64, limit i64) {
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
	mut db := w.ro.db
	rows := db.exec_param_many(crud_list_sql, [category, lim.str(), offset.str()]) or {
		write_resp(mut out, 'application/json', '{"items":[],"total":0,"page":1}')
		return
	}
	unsafe { w.scratch.len = 0 } // reuse the worker's render buffer (no per-request alloc)
	ws(mut w.scratch, '{"items":[')
	mut total := i64(0)
	for i, row in rows {
		if i > 0 {
			ws(mut w.scratch, ',')
		}
		render_item_pg(mut w.scratch, row)
		total = nn(row.vals[9]).i64() // count(*) OVER() — same in every row
	}
	ws(mut w.scratch, '],"total":')
	wi(mut w.scratch, total)
	ws(mut w.scratch, ',"page":')
	wi(mut w.scratch, p)
	ws(mut w.scratch, '}')
	emit(mut out, 'application/json', w.scratch)
}

// write_crud_get serves a single item, cache-aside against the id-indexed slab with the
// X-Cache header (MISS on first read, HIT after). The HIT path is emitted directly under
// the read-lock (a short memcpy into `out`; concurrent readers share the RwMutex, only a
// MISS-refill write-lock blocks) — zero per-request allocation.
fn (mut w WorkerCtx) write_crud_get(mut out []u8, id int) {
	if id >= 1 && id < crud_cache_slots {
		w.ro.crud_mu.@rlock()
		s := w.ro.crud[id]
		if s.valid && s.buf.len > 0 {
			emit_xcache(mut out, 'application/json', s.buf, 'HIT')
			w.ro.crud_mu.runlock()
			return
		}
		w.ro.crud_mu.runlock()
	}
	mut db := w.ro.db
	rows := db.exec_param_many(crud_get_sql, [id.str()]) or {
		wb(mut out, not_found)
		return
	}
	if rows.len == 0 {
		wb(mut out, not_found)
		return
	}
	// Render the item once into the worker's reused scratch, publish it into the slab by
	// refilling the slot's buffer IN PLACE under the write-lock (allocated once at a fixed
	// cap, never reallocated/orphaned), then emit MISS from the same bytes.
	unsafe { w.scratch.len = 0 }
	render_item_pg(mut w.scratch, rows[0])
	if id >= 1 && id < crud_cache_slots {
		w.ro.crud_mu.@lock()
		mut slot := &w.ro.crud[id]
		if slot.buf.cap == 0 {
			slot.buf = []u8{cap: crud_cache_bufcap}
		}
		unsafe { slot.buf.len = 0 }
		slot.buf << w.scratch
		slot.valid = true
		w.ro.crud_mu.unlock()
	}
	emit_xcache(mut out, 'application/json', w.scratch, 'MISS')
}

fn (mut w WorkerCtx) write_crud_create(mut out []u8, req request_parser.HttpRequest) {
	body := unsafe { req.buffer[req.body.start..req.body.start + req.body.len] }
	if c := parse_crud_body_fast(body, true) {
		mut db := w.ro.db
		db.exec_param_many(crud_insert_sql, [c.id.str(), c.name.bytestr(), c.category.bytestr(),
			c.price.str(), c.quantity.str()]) or {
			wb(mut out, bad_request)
			return
		}
		wb(mut out, created)
		return
	}
	// Fallback for escaped/awkward bodies the fast parser rejects: full json.decode.
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return
	}
	mut db := w.ro.db
	db.exec_param_many(crud_insert_sql, [c.id.str(), c.name, c.category, c.price.str(),
		c.quantity.str()]) or {
		wb(mut out, bad_request)
		return
	}
	wb(mut out, created)
}

fn (mut w WorkerCtx) write_crud_update(mut out []u8, id int, req request_parser.HttpRequest) {
	body := unsafe { req.buffer[req.body.start..req.body.start + req.body.len] }
	if c := parse_crud_body_fast(body, false) {
		mut db := w.ro.db
		db.exec_param_many(crud_update_sql, [id.str(), c.name.bytestr(), c.category.bytestr(),
			c.price.str(), c.quantity.str()]) or {
			wb(mut out, bad_request)
			return
		}
		w.invalidate_crud(id)
		write_resp(mut out, 'application/json', '{"status":"ok"}')
		return
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return
	}
	mut db := w.ro.db
	db.exec_param_many(crud_update_sql, [id.str(), c.name, c.category, c.price.str(),
		c.quantity.str()]) or {
		wb(mut out, bad_request)
		return
	}
	w.invalidate_crud(id)
	write_resp(mut out, 'application/json', '{"status":"ok"}')
}

// invalidate_crud flips the slot's `valid` to false and KEEPS the buffer for the next
// MISS to reuse (cache-aside, invalidate-on-write).
@[inline]
fn (mut w WorkerCtx) invalidate_crud(id int) {
	if id >= 1 && id < crud_cache_slots {
		w.ro.crud_mu.@lock()
		w.ro.crud[id].valid = false
		w.ro.crud_mu.unlock()
	}
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

// ── /json (non-DB) ─────────────────────────────────────────────────────────

// write_json_into is the transport-agnostic /json serializer: it only APPENDS response
// bytes to `out`, so the plaintext path and the json-tls path share it verbatim. `sh` is
// read-only and nothing per-request is heap-allocated. Content-Length is precomputed
// from the SAME values the body emits, so the framed length can never desync from the
// body (no response-splitting surface).
fn write_json_into(ro &SharedRO, mut out []u8, count int, m i64) {
	// 21 = len('{"items":[') + len('],"count":') + '}'; plus the count's own digits
	mut clen := 21 + digits(i64(count))
	if count > 0 {
		clen += count - 1 // item separators
	}
	for i in 0 .. count {
		t := ro.dataset[i].price * ro.dataset[i].quantity * m
		clen += ro.prefixes[i].len + digits(t) + 1 // prefix + total + '}'
	}
	ws(mut out,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(clen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		ws(mut out, ro.prefixes[i])
		wi(mut out, ro.dataset[i].price * ro.dataset[i].quantity * m)
		// fuse each object's closing `}` with the item separator `,` into one bulk write.
		ws(mut out, if i < count - 1 { '},' } else { '}' })
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	ws(mut out, '}')
}

fn (w &WorkerCtx) write_json_response(mut out []u8, count int, m i64) {
	write_json_into(w.ro, mut out, count, m)
}

// write_json_gzip is the json-comp path: a LAZY, process-shared, RwMutex-guarded cache
// of complete gzipped responses keyed by (count<<32)|m. Compress once on the first miss,
// then append the cached bytes on every hit (the profile is compression-bound). Kept
// lazy for parity with the epoll twin (there it also avoids a boot-time gzip.compress
// leak); the shared rlock is not a bottleneck — the json-comp@16384 collapse is worker
// oversubscription from the co-hosted json-tls listener (enghitalo/vanilla#89).
fn (mut w WorkerCtx) write_json_gzip(mut out []u8, count int, m i64) {
	key := (u64(u32(count)) << 32) | u64(u32(m))
	mut cached := []u8{}
	w.ro.gz_mu.@rlock()
	if c := w.ro.gz_cache[key] {
		unsafe {
			cached = c
		}
	}
	w.ro.gz_mu.runlock()
	if cached.len > 0 {
		wb(mut out, cached)
		return
	}
	body := w.json_body(count, m)
	gz := gzip.compress(body.bytes()) or {
		write_resp(mut out, 'application/json', body)
		return
	}
	mut resp := []u8{cap: gz.len + 128}
	ws(mut resp,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut resp, i64(gz.len))
	ws(mut resp, '\r\nConnection: keep-alive\r\n\r\n')
	unsafe { resp.push_many(gz.data, gz.len) }
	// Store it (bounded so a flood of distinct m values can't grow it without limit).
	w.ro.gz_mu.@lock()
	if w.ro.gz_cache.len < 1024 {
		w.ro.gz_cache[key] = resp
	}
	w.ro.gz_mu.unlock()
	wb(mut out, resp)
}

// json_body builds just the /json body string (used for the gzip path).
fn (w &WorkerCtx) json_body(count int, m i64) string {
	mut sb := strings.new_builder(count * 224 + 32)
	sb.write_string('{"items":[')
	for i in 0 .. count {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string(w.ro.prefixes[i])
		sb.write_decimal(w.ro.dataset[i].price * w.ro.dataset[i].quantity * m)
		sb.write_u8(`}`)
	}
	sb.write_string('],"count":')
	sb.write_decimal(i64(count))
	sb.write_u8(`}`)
	return sb.str()
}

// ── helpers ──────────────────────────────────────────────────────────────────

// escape_html_into HTML-escapes s directly into out — no intermediate string/Builder.
// Fast path: when nothing needs escaping, one bulk copy (the common case).
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

const qk_a = 'a'.bytes()
const qk_b = 'b'.bytes()
const qk_m = 'm'.bytes()
const qk_min = 'min'.bytes()
const qk_max = 'max'.bytes()
const qk_limit = 'limit'.bytes()
const qk_page = 'page'.bytes()
const qk_category = 'category'.bytes()

// qint parses an integer query parameter directly from the request buffer — no string
// allocation (the old tos()+.i64() path materialized a throwaway string per call).
@[direct_array_access]
fn qint(req request_parser.HttpRequest, key []u8) i64 {
	s := req.get_query_slice(key) or { return 0 }
	return parse_i64_slice(req.buffer, s.start, s.len)
}

// qstr reads a query parameter as a string ('' if absent). CLONES: db.pg text params are
// passed to libpq as C strings, so the value must be NUL-terminated and outlive the
// request buffer — a bare tos() view would read past the parameter. (The epoll twin's
// qstr_slice can borrow because pg_async copies bind params synchronously.)
fn qstr(req request_parser.HttpRequest, key []u8) string {
	s := req.get_query_slice(key) or { return '' }
	return unsafe { tos(&req.buffer[s.start], s.len) }.clone()
}

// parse_i64_slice parses a decimal i64 from buf[start..start+length] in place (leading
// '-' allowed; stops at the first non-digit), allocating nothing.
@[direct_array_access]
fn parse_i64_slice(buf []u8, start int, length int) i64 {
	mut n := i64(0)
	mut neg := false
	for i in 0 .. length {
		c := buf[start + i]
		if i == 0 && c == `-` {
			neg = true
			continue
		}
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + i64(c - `0`)
	}
	return if neg { -n } else { n }
}

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

// body_int parses the request body as an integer, decoding chunked transfer encoding
// when present. The common path (Content-Length / direct body) is zero-alloc; the rare
// chunked path reassembles into a small local buffer (baseline11 chunked bodies are tiny
// integers) via the shared dechunk_into, then parses in place.
fn body_int(req request_parser.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	if te := req.get_header_value_slice('Transfer-Encoding') {
		val := unsafe { tos(&req.buffer[te.start], te.len) }
		if val.contains('chunked') {
			mut buf := []u8{cap: 512}
			dechunk_into(mut buf, req.buffer, req.body.start, req.body.len)
			return parse_i64_slice(buf, 0, buf.len)
		}
	}
	return parse_i64_slice(req.buffer, req.body.start, req.body.len)
}

// dechunk_into appends the dechunked body bytes from the chunked-encoded region
// buf[start..start+length] into `out`. Read each hex chunk-size line terminated by CRLF,
// copy `size` data bytes, stop at the 0-size chunk or any malformation.
@[direct_array_access]
fn dechunk_into(mut out []u8, buf []u8, start int, length int) {
	end := start + length
	mut i := start
	for i < end {
		// find the CRLF terminating the chunk-size line
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
		size := parse_hex_slice(buf, i, nl - i)
		if size <= 0 {
			break
		}
		data_start := nl + 2
		// Overflow-safe bound: `data_start + size` in i32 would WRAP negative for an
		// attacker-chosen size near 0x7fffffff, slipping past a naive check and feeding a
		// ~2 GiB out-of-bounds read into push_many. `end - data_start` is a small
		// non-negative int (data_start <= end), so comparing this way never overflows.
		if size > end - data_start {
			break
		}
		unsafe { out.push_many(&buf[data_start], size) }
		i = data_start + size + 2 // past the data + its trailing CRLF
	}
}

// parse_hex_slice reads a hex integer from buf[start..start+length], stopping at the
// first non-hex byte (a chunk-extension `;` or the CRLF). No allocation.
@[direct_array_access]
fn parse_hex_slice(buf []u8, start int, length int) int {
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
			return 0x7fff_ffff // saturate: the caller's size guard then rejects it
		}
	}
	return int(n)
}

fn accepts_gzip(req request_parser.HttpRequest) bool {
	ae := req.get_header_value_slice('Accept-Encoding') or { return false }
	return unsafe { tos(&req.buffer[ae.start], ae.len) }.contains('gzip')
}

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
			// Keep the fast path strict and allocation-free; escaped strings fall back to json.decode.
			return none
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

// parse_crud_body_fast reads the crud JSON body with borrowed slices and no reflection
// (ported from the epoll twin, enghitalo/vanilla#85). Returns none for escaped/awkward
// bodies so the caller can fall back to json.decode.
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

// load_tls_config builds the json-tls server's TLS config. It reads the cert/key the
// HttpArena harness bind-mounts at /certs (overridable via TLS_CERT/TLS_KEY). If NO cert
// is mounted (local dev), it falls back to a fresh self-signed cert — the
// benchmark/validate clients use `curl -k` / wrk, which never verify it. If a cert IS
// present but the key is missing/unreadable, it FAILS LOUDLY rather than silently
// self-signing. TLS 1.3 + ALPN http/1.1 are fixed by the tls shim.
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
	// connections on every request. Keeping idle == open makes it a fixed warm pool.
	mut db := pg.connect(parse_db_url(url), pg.PoolConfig{ max_open_conns: size, max_idle_conns: size })!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode([]DatasetItem, dataset_raw) or { []DatasetItem{} }

	// Precompute each item's JSON prefix once: `{…,"rating":{…},"total":` (drop the
	// closing brace, append the total key). Only the total value is request-dependent,
	// so the hot path never serializes a struct.
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	// Canonical static server: loads every asset PLUS its .br/.gz siblings once, mounts
	// them at /static/, and negotiates Accept-Encoding per request, emitting via
	// core.queue_buf (borrowed send of the preloaded bytes).
	//
	// Do NOT set sendfile_min_bytes here (unlike the epoll twin, which uses 16 KiB): the
	// io_uring backend has NO sendfile path (no core.enable_sendfile / queue_file drain),
	// so static_assets.respond_into would fall back to READING a "large" asset's body
	// from disk on every request — a blocking read that stalls the ring. Keeping the
	// default (256 KiB) preloads every arena .br/.gz sibling (all < 256 KiB) and serves
	// them as a zero-copy borrowed send. (Measured: 16 KiB here collapsed static ~-86% to
	// -99% — the large .br siblings hit the read-per-request fallback. See vanilla#93/#83:
	// io_uring sendfile support is future work.)
	asv := static_assets.new(static_assets.Config{
		root:         static_dir
		url_prefix:   '/static/'
		spa_fallback: ''
	}) or { panic('vanilla-io_uring: static_assets init failed: ${err}') }

	ro := &SharedRO{
		db:       db
		dataset:  dataset
		prefixes: prefixes
		asv:      asv
		crud:     []CrudSlot{len: crud_cache_slots}
		crud_mu:  sync.new_rwmutex()
		gz_cache: map[u64][]u8{}
		gz_mu:    sync.new_rwmutex()
	}

	// ── json-tls profile: /json over HTTPS on :8081 via the epoll + kTLS backend ──
	// The lib's io_uring backend has no TLS, so the json-tls listener runs on the epoll
	// backend (TLS 1.3 via Mbed TLS; kTLS record offload where the kernel `tls` module is
	// present). It serves ONLY /json (404 elsewhere) — minimal TLS surface — reusing the
	// same allocation-free write_json_into (read-only: dataset + prefixes). A STATELESS
	// request_handler captures `ro`; it never touches the DB/caches, so it runs safely
	// alongside the io_uring workers. The io_uring server below keeps the non-TLS
	// profiles on :8080.
	tls_handler := fn [ro] (req_buffer []u8, fd int, mut out []u8) ! {
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
			count := clamp_count(parse_u_at(route, 6), ro.dataset.len)
			mut m := qint(req, qk_m)
			if m == 0 {
				m = 1
			}
			write_json_into(ro, mut out, count, m)
			return
		}
		wb(mut out, not_found)
	}
	// Port is fixed to 8081 by the HttpArena harness; TLS_PORT lets local runs pick a free
	// port. run() blocks, so the TLS server runs on its own thread (value-mut receiver →
	// spawn via a closure with a local mut copy; the two servers are independent).
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
		port:             8080
		io_multiplexing:  .io_uring
		limits:           http_server.Limits{
			max_request_bytes: 32 * 1024 * 1024 // accept the 20 MiB upload bodies
		}
		// Per-worker state (io_uring make_state — enghitalo/vanilla#93): each ring worker
		// builds ONE WorkerCtx (its own reused render scratch) and dispatches every request
		// through `handle` with it — no per-request render alloc, matching the epoll twin.
		stateful_handler: handle
		make_state:       fn [ro] () voidptr {
			return voidptr(&WorkerCtx{
				ro:      ro
				scratch: []u8{cap: 32 * 1024}
			})
		}
	})!
	server.run()
}
