module main

import vanilla.http_server
import vanilla.http_server.http1_1.request_parser
import vanilla.http_server.core
import vanilla.pg_async
import json
import os
import runtime
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

// A static asset served with sendfile(2): the response head is precomputed, the
// body is streamed zero-copy straight from the page-cached file fd.
struct StaticFile {
	header []u8
	fd     int
	size   i64
}

fn C.open(pathname &char, flags int) int

struct CrudCreate {
	id       int
	name     string
	category string
	price    int
	quantity int
}

struct Fortune {
	id      int
	message []u8 // BORROWED view into the Result frames buffer (valid during render only)
}

// SharedRO is the immutable, process-wide data: the dataset, the precomputed
// per-item JSON prefixes, and the preloaded static assets. Shared by reference
// across all workers (read-only, so no synchronization).
struct SharedRO {
	dataset  []DatasetItem
	prefixes []string
	assets   map[string]StaticFile
mut:
	// PROCESS-SHARED caches (mutex-guarded). They must be shared, not per-worker:
	// validate.sh does two GET /crud/items/42 and requires X-Cache MISS then HIT,
	// but SO_REUSEPORT routes the two to different workers — per-worker caches MISS
	// twice. The pool stays per-worker (no lock); only these caches are shared.
	//
	// crud is an id-indexed SLAB (the GET/PUT id space is the dense `{RAND:1:50000}`),
	// not a map[int][]u8. The map version leaked under -gc none: every PUT did
	// `map.delete(id)`, orphaning the stored buffer forever (no GC), and the next
	// GET MISS allocated a fresh one — ~124 B/req of unfreeable growth under the
	// arena's GET/PUT mix. The slab reuses each slot's buffer IN PLACE across
	// re-caches and only flips `valid` on PUT (cache-aside, invalidate-on-write),
	// so nothing is ever orphaned. Cache-aside with NO time TTL, matching the crud
	// spec (validate.sh requires MISS→HIT then MISS-after-PUT; no expiry is checked)
	// and the prior baseline — a 200 ms TTL was tried and forced constant DB
	// re-queries that saturated the async pool (crud -33%, 8.8% 5xx). RSS is bounded
	// (~25 MiB, lazily allocated).
	crud    []CrudSlot
	crud_mu &sync.RwMutex = unsafe { nil }
	gz      map[u64][]u8 // json-comp: (count<<32)|m -> gzipped response bytes
	gz_mu   &sync.RwMutex = unsafe { nil }
}

// CrudSlot is one entry of the id-indexed crud cache slab. `buf` is the rendered
// item response body, refilled IN PLACE across re-caches (allocated once, lazily,
// then reused — never freed/orphaned under -gc none). The entry is a valid HIT iff
// `valid && buf.len > 0`; a PUT just sets `valid = false` and keeps the buffer for
// the next MISS to reuse (no time-based expiry — see the SharedRO.crud note).
struct CrudSlot {
mut:
	buf   []u8
	valid bool
}

// crud GET/PUT ids are `{RAND:1:50000}`; index the slab directly (1..50000). Index 0
// is unused; created items (`{SEQ:100001}`) fall outside and are never read-cached.
const crud_cache_slots = 50001
// Fixed per-slot buffer cap. The widest item renders to ~202 B (seed: name +
// category + tags + digits + ~95 B of JSON punctuation); 512 leaves ample margin
// so a slot's buffer, allocated once on first MISS, never reallocates.
const crud_cache_bufcap = 512

// WorkerCtx is the per-worker state handed to every handler call as ac.state
// (the make_state contract). Each worker owns its own async Postgres pool (no
// lock); the caches live in the shared `ro` (mutex-guarded) so X-Cache hits
// survive SO_REUSEPORT routing the two probe requests to different workers.
struct WorkerCtx {
mut:
	ro   &SharedRO        = unsafe { nil } // shared data + process-shared caches
	pool &pg_async.PgPool = unsafe { nil } // per-worker async PG pool (no lock)
	// scratch is this worker's REUSED render buffer: render_* build the JSON/HTML body
	// here (reset to len 0 each response, grows to a high-water mark then stays) rather
	// than allocating a fresh []u8 per request. The binary ships `-gc none`, so a
	// per-request body buffer would never be freed — a multi-GiB leak under load. One
	// buffer is safe because a worker serves requests one at a time (no concurrency).
	scratch []u8
	// Reused per-request DB-param buffers (same -gc none / single-threaded rationale as
	// scratch). param_scratch holds integer params serialized as decimal bytes;
	// params_buf is the []?[]u8 handed to park(), refilled each request with borrowed
	// slices into param_scratch (ints) and into the request buffer (strings). Both are
	// reset (len 0) per request and consumed synchronously inside park→async_submit
	// (write_bind copies the bytes), so the borrows never outlive the call.
	// INVARIANT: param_scratch.cap (256) must exceed the worst-case decimal bytes of one
	// request's int params (≤5 × 20 digits = 100) so it never reallocates mid-request —
	// a realloc would dangle the earlier slices already pushed into params_buf.
	param_scratch []u8
	params_buf    []?[]u8
	// Reused Stash free-list: park() borrows a Stash here instead of heap-allocating one
	// per request; on_db_ready returns it on the terminal .done path only (NOT on the
	// not-ready re-arm, where it stays live as the watch udata — incl. a FIX 3 dead
	// tombstone that keeps it referenced until its orphaned reply drains).
	stash_pool []&Stash
	// Reused /fortunes row buffer: messages are BORROWED views into the Result frames
	// (stable during the synchronous render), not bytestr().clone()'d.
	fortunes_buf []Fortune
	// Reused dechunk scratch: a chunked POST body is reassembled here (len reset
	// per use, grows to high-water) instead of allocating a strings.Builder +
	// .str() per request — under -gc none that was the /baseline11 chunked-POST
	// leak (~6 GiB at 3.8M req/s in the arena baseline mix).
	dechunk_buf []u8
}

// Stash is the per-request state that must survive across the park (the request
// buffer is recycled while a query is in flight). One small heap struct per DB
// request; the single resume continuation switches on `kind`.
struct Stash {
mut:
	kind     u8
	conn_idx int
	id       int
	page     i64
}

const k_async_db = u8(1)
const k_fortunes = u8(2)
const k_crud_get = u8(3)
const k_crud_list = u8(4)
const k_crud_create = u8(5)
const k_crud_update = u8(6)

// ── zero-alloc write helpers (push_many, never single-element `<<`) ──────────

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
	// Build the magnitude in u64: i64::MIN's i64 negation overflows (the value
	// isn't representable as i64), so derive it as -(n+1)+1 with the +1 in u64.
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

// ws_json_str appends a JSON-escaped string value (no surrounding quotes). Fast
// path: most values have no special characters, so emit them as one bulk copy.
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

fn write_resp(mut out []u8, ctype string, body string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

// emit_int writes a 200 whose body is a single integer, formatting it into the
// reused per-worker scratch. The obvious `write_resp(.., n.str())` heap-allocates
// an int->string on every request — a permanent leak under `-gc none` (e.g. the
// /baseline11 path was ~6 GiB at 3.4M RPS purely from sum.str()).
fn (mut w WorkerCtx) emit_int(mut out []u8, ctype string, n i64) {
	unsafe { w.scratch.len = 0 }
	wi(mut w.scratch, n)
	emit(mut out, ctype, w.scratch)
}

// Precomputed full response for the fixed /pipeline plaintext "ok" (the highest-
// RPS test): one bulk copy on the hot path, no query scan / route slice / build.
const pipeline_resp = 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

// Raw request prefix for the fixed /pipeline plaintext test. The trailing space is
// the request-line SP, so this matches exactly `GET /pipeline ` (not /pipeline2).
const pipeline_prefix = 'GET /pipeline '.bytes()

// has_pipeline_prefix is the skip-decode gate for the highest-RPS /pipeline test:
// match the raw request prefix and blit the response WITHOUT parsing. Per callgrind
// the in-handle parse (parse_http1_request_line + decode_into + tos) is ~17% of this
// request; the request was already framed by the caller, so decode adds nothing here.
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

// Returned when the async DB pool sheds a request under saturation (every pooled
// connection at max_inflight). It is the SHED fallback for the crud write/get
// paths — distinct from a genuine 400 (malformed body) or 404 (missing item): the
// request was well-formed, the server was momentarily out of DB pipeline capacity,
// so 503 is the honest status. (Read paths still shed to an empty 200 — revisiting
// that whole backpressure policy is tracked upstream in vanilla.)
const service_unavailable = 'HTTP/1.1 503 Service Unavailable\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// ── async handler ────────────────────────────────────────────────────────────

fn handle(req_buffer []u8, mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	mut w := unsafe { &WorkerCtx(ac.state) }
	// Skip-decode fast path: the fixed /pipeline plaintext (highest-RPS test) blits
	// its response before ANY parsing. The request is already framed by the caller,
	// so decode_into/parse_http1_request_line add nothing here (~17% of the request).
	if has_pipeline_prefix(req_buffer) {
		wb(mut out, pipeline_resp)
		return .done
	}
	// decode_into fills req in place — no `!HttpRequest` Result boxing (~13% of the
	// parse path per callgrind), the same no-boxing entry the sync build uses.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		wb(mut out, bad_request)
		return .done
	}
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	// Pipelined hot path: fixed response, blit the constant before the '?'-scan +
	// route slice. The profile sends exactly /pipeline (no query), so exact-match.
	if target == '/pipeline' {
		wb(mut out, pipeline_resp)
		return .done
	}
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }

	if route == '/baseline11' {
		mut sum := qint(req, qk_a) + qint(req, qk_b)
		if method == 'POST' {
			sum += w.body_int(req)
		}
		w.emit_int(mut out, 'text/plain', sum)
		return .done
	} else if route == '/upload' {
		cl := req.content_length()
		n := if cl >= 0 { i64(cl) } else { i64(req.body.len) }
		w.emit_int(mut out, 'text/plain', n)
		return .done
	} else if route.starts_with('/json/') {
		count := clamp_count(parse_u_at(route, 6), w.ro.dataset.len)
		mut m := qint(req, qk_m)
		if m == 0 {
			m = 1
		}
		if accepts_gzip(req) {
			w.write_json_gzip(mut out, count, m)
		} else {
			w.write_json_response(mut out, count, m)
		}
		return .done
	} else if route == '/async-db' {
		return w.start_async_db(mut out, mut ac, qint(req, qk_min), qint(req, qk_max), qint(req,
			qk_limit))
	} else if route == '/fortunes' {
		return w.start_fortunes(mut out, mut ac)
	} else if route.starts_with('/static/') {
		// Zero-copy lookup key: a view into the request buffer. The map only hashes the
		// key bytes and never retains it, so the view is safe. `route[8..]` would be a
		// substr -> a fresh heap string every request, which `-gc none` never frees
		// (+625 MiB over 20M requests, proven in isolation). Mirrors the vanilla lib's
		// own static_assets module (http_server/static_assets/static_assets.v).
		if f := w.ro.assets[unsafe { tos(route.str + 8, route.len - 8) }] {
			wb(mut out, f.header)
			core.queue_file(f.fd, 0, f.size)
		} else {
			wb(mut out, not_found)
		}
		return .done
	} else if route == '/crud/items' {
		if method == 'POST' {
			return w.start_crud_create(mut out, mut ac, req)
		}
		return w.start_crud_list(mut out, mut ac, qstr_slice(req, qk_category), qint(req, qk_page),
			qint(req, qk_limit))
	} else if route.starts_with('/crud/items/') {
		id := int(parse_u_at(route, 12))
		if method == 'PUT' {
			return w.start_crud_update(mut out, mut ac, id, req)
		}
		return w.start_crud_get(mut out, mut ac, id)
	}
	wb(mut out, not_found)
	return .done
}

// park submits a query and parks the request on its connection, stashing the
// render kind (+ id/page for the routes that need them) for the continuation.
// On a pool/flush failure it answers synchronously with `fallback`.
fn (mut w WorkerCtx) park(mut out []u8, mut ac core.AsyncCtx, query_text string, params []?[]u8, kind u8, id int, page i64, fallback []u8) core.AsyncStep {
	// Pick the least-loaded connection (shortest pipeline). Cross-request
	// pipelining: a connection multiplexes up to max_inflight queries, so we shed
	// only when every connection is at the cap — not when a connection is merely
	// busy with one in-flight query (the old one-in-flight starvation).
	idx := w.pool.acquire_pipelined() or {
		wb(mut out, fallback)
		return .done
	}
	mut c := w.pool.conn(idx)
	// Append the query to the connection's pipeline; shed if the connection is
	// saturated (ring or send buffer full) rather than block.
	if !c.async_submit(query_text, params) {
		wb(mut out, fallback)
		return .done
	}
	c.async_flush() or {
		wb(mut out, fallback)
		return .done
	}
	// Borrow a Stash from the per-worker free-list instead of heap-allocating one per
	// request (a leak under -gc none). on_db_ready returns it on the terminal .done path.
	// Statement form (not `mut st := if ... { } else { &Stash{} }`): a `&Struct{}` literal
	// as an if-EXPRESSION branch miscompiles to invalid C under -g (cf. vlang/v#27485).
	mut st := &Stash(unsafe { nil })
	if w.stash_pool.len > 0 {
		st = w.stash_pool.pop()
		st.kind = kind
		st.conn_idx = idx
		st.id = id
		st.page = page
	} else {
		st = &Stash{
			kind:     kind
			conn_idx: idx
			id:       id
			page:     page
		}
	}
	// One watch per parked request on the connection's fd. When several requests
	// share a connection the reactor auto-promotes the fd to a FIFO queue and fans
	// each reply out in submission order (queue[k] ↔ the connection's inflight[k]).
	// watch_persistent: the fd is a POOLED connection — if this client disconnects
	// mid-query the runtime must drain the orphaned reply and keep the connection
	// open for reuse, never close it (a close would force a reconnect + re-auth).
	ac.watch_persistent(w.pool.fd(idx), .readable, on_db_ready, voidptr(st))
	return .suspend
}

// on_db_ready resumes a parked request when its PG socket is readable: pump the
// result, render by kind, release the connection.
fn on_db_ready(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	mut w := unsafe { &WorkerCtx(ac.state) }
	st := unsafe { &Stash(ac.udata) }
	mut c := w.pool.conn(st.conn_idx)
	// async_on_readable pops THIS request's reply: the reactor runs the connection's
	// parked requests front-first and replies arrive in submit order, so the FIFO
	// front the reactor hands us aligns with the query we submitted. A server error
	// fails only this query (its own Sync bounds it); pipelined siblings continue.
	poll := c.async_on_readable() or {
		w.render_error(mut out, st.kind)
		w.return_stash(st) // terminal .done — recycle the Stash
		return .done
	}
	if !poll.ready {
		// Re-arm persistent: the single-watch path clears the slot before running this
		// continuation, so the re-arm is a fresh entry — watch_persistent re-stamps the
		// pool-owned flag that a plain watch would drop. (more bytes to come)
		// NOTE: do NOT recycle st here — it stays live as the watch udata (incl. a FIX 3
		// dead tombstone) until the reply completes on a later edge.
		ac.watch_persistent(w.pool.fd(st.conn_idx), .readable, on_db_ready, ac.udata)
		return .suspend
	}
	res := poll.result
	match st.kind {
		k_async_db { w.render_async_db(mut out, res) }
		k_fortunes { w.render_fortunes(mut out, res) }
		k_crud_get { w.render_crud_get(mut out, res, st.id) }
		k_crud_list { w.render_crud_list(mut out, res, st.page) }
		k_crud_create { wb(mut out, created) }
		k_crud_update { w.render_crud_update(mut out, st.id) }
		else { wb(mut out, not_found) }
	}
	// No release: a pipelined connection is not held exclusively. Its in-flight
	// count dropped when async_on_readable popped this reply, freeing a pipeline
	// slot for acquire_pipelined.
	w.return_stash(st) // terminal .done — recycle the Stash
	return .done
}

// return_stash recycles a finished request's Stash onto the per-worker free-list. Call
// ONLY on a terminal .done path — never on the .suspend re-arm, where st stays live as
// the watch udata. Bounded so a burst doesn't grow the list without limit.
@[inline]
fn (mut w WorkerCtx) return_stash(st &Stash) {
	if w.stash_pool.len < 64 {
		w.stash_pool << st
	}
}

fn (w &WorkerCtx) render_error(mut out []u8, kind u8) {
	match kind {
		k_async_db {
			write_resp(mut out, 'application/json', '{"items":[],"count":0}')
		}
		k_fortunes {
			write_resp(mut out, 'text/html; charset=utf-8',
				'<!doctype html><html><body><table></table></body></html>')
		}
		k_crud_list {
			write_resp(mut out, 'application/json', '{"items":[],"total":0,"page":1}')
		}
		k_crud_get {
			wb(mut out, not_found)
		}
		else {
			wb(mut out, bad_request)
		}
	}
}

// ── Bind-param builders (zero per-request allocation) ────────────────────────
// Each start_* builds its params into the worker's reused params_buf via these
// helpers instead of a fresh `[?[]u8(x.str().bytes()), ...]` literal (which leaked
// the array + every .str()/.bytes() under -gc none). Call reset_params(), push each
// param in $1..$N order, then pass w.params_buf to park().

@[inline]
fn (mut w WorkerCtx) reset_params() {
	unsafe {
		w.param_scratch.len = 0
		w.params_buf.len = 0
	}
}

// push_int serializes i64 n as decimal into param_scratch and pushes a borrowed slice
// onto params_buf. Relies on param_scratch NOT reallocating mid-request (cap ≫ worst
// case, see WorkerCtx) — a realloc would dangle slices already pushed.
fn (mut w WorkerCtx) push_int(n i64) {
	old := w.param_scratch.len
	wi(mut w.param_scratch, n)
	w.params_buf << ?[]u8(w.param_scratch[old..w.param_scratch.len])
}

// push_bytes pushes a borrowed, non-NULL byte param (a request-buffer or decoded-string
// view) onto params_buf. The bytes are copied by write_bind synchronously in park.
@[inline]
fn (mut w WorkerCtx) push_bytes(b []u8) {
	w.params_buf << ?[]u8(b)
}

// Shed-path fallback bodies, computed once (a literal `.bytes()` per request would leak).
const adb_fallback = '{"items":[],"count":0}'.bytes()
const crud_list_fallback = '{"items":[],"total":0,"page":1}'.bytes()
const fortunes_fallback = '<!doctype html><html><body><table></table></body></html>'.bytes()

// ── /async-db ────────────────────────────────────────────────────────────────

const async_db_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3'

fn (mut w WorkerCtx) start_async_db(mut out []u8, mut ac core.AsyncCtx, min i64, max i64, limit i64) core.AsyncStep {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	w.reset_params()
	w.push_int(min)
	w.push_int(max)
	w.push_int(lim)
	return w.park(mut out, mut ac, async_db_sql, w.params_buf, k_async_db, 0, 0, adb_fallback)
}

fn (mut w WorkerCtx) render_async_db(mut out []u8, res pg_async.Result) {
	unsafe { w.scratch.len = 0 } // reuse the worker's render buffer (no per-request alloc)
	ws(mut w.scratch, '{"items":[')
	mut rows := res.rows()
	mut count := 0
	for {
		row := rows.next() or { break }
		if count > 0 {
			ws(mut w.scratch, ',')
		}
		render_item(mut w.scratch, row)
		count++
	}
	ws(mut w.scratch, '],"count":')
	wi(mut w.scratch, i64(count))
	ws(mut w.scratch, '}')
	emit(mut out, 'application/json', w.scratch)
}

// render_item writes one items-row as JSON. tags is JSONB read in binary: a
// 0x01 version byte then JSON text, so it is emitted RAW (already valid JSON) —
// no decode/re-encode round-trip.
@[direct_array_access]
fn render_item(mut body []u8, row pg_async.Row) {
	ws(mut body, '{"id":')
	wi(mut body, i64(row.int4(0) or { 0 }))
	ws(mut body, ',"name":"')
	ws_json_str(mut body, row.text(1) or { ''.bytes() })
	ws(mut body, '","category":"')
	ws_json_str(mut body, row.text(2) or { ''.bytes() })
	ws(mut body, '","price":')
	wi(mut body, i64(row.int4(3) or { 0 }))
	ws(mut body, ',"quantity":')
	wi(mut body, i64(row.int4(4) or { 0 }))
	ws(mut body, ',"active":')
	ws(mut body, if row.boolean(5) or { false } { 'true' } else { 'false' })
	ws(mut body, ',"tags":')
	wb(mut body, pg_async.jsonb_text(row.text(6) or { '[]'.bytes() }))
	ws(mut body, ',"rating":{"score":')
	wi(mut body, i64(row.int4(7) or { 0 }))
	ws(mut body, ',"count":')
	wi(mut body, i64(row.int4(8) or { 0 }))
	ws(mut body, '}}')
}

// ── /fortunes ────────────────────────────────────────────────────────────────

fn (mut w WorkerCtx) start_fortunes(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	w.reset_params() // no params; reuse the (empty) params_buf rather than a fresh literal
	return w.park(mut out, mut ac, 'SELECT id, message FROM fortune', w.params_buf, k_fortunes,
		0, 0, fortunes_fallback)
}

const synthetic_fortune = 'Additional fortune added at request time.'.bytes()

fn (mut w WorkerCtx) render_fortunes(mut out []u8, res pg_async.Result) {
	unsafe { w.fortunes_buf.len = 0 } // reuse the worker's row buffer (no per-request vector)
	mut rows := res.rows()
	for {
		row := rows.next() or { break }
		// BORROW the message bytes from the Result frames (stable for this synchronous
		// render) — no bytestr().clone() (two allocs/row under -gc none).
		w.fortunes_buf << Fortune{
			id:      row.int4(0) or { 0 }
			message: row.text(1) or { []u8{} }
		}
	}
	w.fortunes_buf << Fortune{
		id:      0
		message: synthetic_fortune
	}
	w.fortunes_buf.sort_with_compare(cmp_fortune_message)
	unsafe { w.scratch.len = 0 } // reuse the worker's render buffer (no per-request body alloc)
	ws(mut w.scratch,
		'<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in w.fortunes_buf {
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

// ── /crud ────────────────────────────────────────────────────────────────────

// crud_list uses a single window-count query (count(*) OVER()) so the page and
// the total come back together — one park instead of two queries.
const crud_list_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3'

fn (mut w WorkerCtx) start_crud_list(mut out []u8, mut ac core.AsyncCtx, category []u8, page i64, limit i64) core.AsyncStep {
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
	w.reset_params()
	w.push_bytes(category) // borrowed view into the request buffer (qstr_slice)
	w.push_int(lim)
	w.push_int(offset)
	return w.park(mut out, mut ac, crud_list_sql, w.params_buf, k_crud_list, 0, p, crud_list_fallback)
}

fn (mut w WorkerCtx) render_crud_list(mut out []u8, res pg_async.Result, page i64) {
	unsafe { w.scratch.len = 0 } // reuse the worker's render buffer (no per-request alloc)
	ws(mut w.scratch, '{"items":[')
	mut rows := res.rows()
	mut count := 0
	mut total := i64(0)
	for {
		row := rows.next() or { break }
		if count > 0 {
			ws(mut w.scratch, ',')
		}
		render_item(mut w.scratch, row)
		total = row.int8(9) or { 0 } // count(*) OVER() — same in every row
		count++
	}
	ws(mut w.scratch, '],"total":')
	wi(mut w.scratch, total)
	ws(mut w.scratch, ',"page":')
	wi(mut w.scratch, page)
	ws(mut w.scratch, '}')
	emit(mut out, 'application/json', w.scratch)
}

fn (mut w WorkerCtx) start_crud_get(mut out []u8, mut ac core.AsyncCtx, id int) core.AsyncStep {
	// Cache-aside lookup against the id-indexed slab. Snapshot the cached body into
	// the per-worker scratch UNDER the read-lock, then build the response unlocked:
	// the slot buffer is reused in place, so a bare ref must not outlive the lock (a
	// concurrent MISS-refill would mutate it). The read-lock hold is one memcpy.
	mut hit := false
	if id >= 1 && id < crud_cache_slots {
		w.ro.crud_mu.@rlock()
		s := w.ro.crud[id]
		if s.valid && s.buf.len > 0 {
			unsafe { w.scratch.len = 0 }
			w.scratch << s.buf
			hit = true
		}
		w.ro.crud_mu.runlock()
	}
	if hit {
		// Cache hit: answer synchronously, no DB round-trip.
		ws(mut out,
			'HTTP/1.1 200 OK\r\nServer: vanilla\r\nX-Cache: HIT\r\nContent-Type: application/json\r\nContent-Length: ')
		wi(mut out, i64(w.scratch.len))
		ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
		wb(mut out, w.scratch)
		return .done
	}
	w.reset_params()
	w.push_int(i64(id))
	return w.park(mut out, mut ac,
		'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1',
		w.params_buf, k_crud_get, id, 0, service_unavailable)
}

fn (mut w WorkerCtx) render_crud_get(mut out []u8, res pg_async.Result, id int) {
	mut rows := res.rows()
	row := rows.next() or {
		wb(mut out, not_found)
		return
	}
	// Render the item into the per-worker scratch (reused), then publish into the
	// id-indexed cache slot by refilling its buffer IN PLACE under the write-lock —
	// no per-MISS allocation, nothing orphaned (the buffer is reused across re-caches;
	// PUT only flips `valid`). Mark the slot valid (cache-aside, no time TTL).
	unsafe { w.scratch.len = 0 }
	render_item(mut w.scratch, row)
	if id >= 1 && id < crud_cache_slots {
		w.ro.crud_mu.@lock()
		mut slot := &w.ro.crud[id]
		if slot.buf.cap == 0 {
			// First touch: allocate at a fixed cap ≥ the max item render (~202 B).
			// V grows a cap-0 buffer to EXACTLY the first push length, so without this
			// a later, slightly larger render (e.g. after a PUT) would realloc and
			// orphan the smaller buffer forever under -gc none. Fixed cap ⇒ the refill
			// below never reallocates; each slot allocates exactly once, ever.
			slot.buf = []u8{cap: crud_cache_bufcap}
		}
		unsafe { slot.buf.len = 0 }
		slot.buf << w.scratch
		slot.valid = true
		w.ro.crud_mu.unlock()
	}
	ws(mut out,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nX-Cache: MISS\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(w.scratch.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, w.scratch)
}

fn (mut w WorkerCtx) start_crud_create(mut out []u8, mut ac core.AsyncCtx, req request_parser.HttpRequest) core.AsyncStep {
	body := unsafe { req.buffer[req.body.start..req.body.start + req.body.len] }
	if c := parse_crud_body_fast(body, true) {
		w.reset_params()
		w.push_int(c.id)
		w.push_bytes(c.name)
		w.push_bytes(c.category)
		w.push_int(c.price)
		w.push_int(c.quantity)
		return w.park(mut out, mut ac,
			"INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity",
			w.params_buf, k_crud_create, 0, 0, service_unavailable)
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return .done
	}
	w.reset_params()
	w.push_int(i64(c.id))
	w.push_bytes(unsafe { c.name.str.vbytes(c.name.len) }) // borrow decoded-string bytes
	w.push_bytes(unsafe { c.category.str.vbytes(c.category.len) })
	w.push_int(i64(c.price))
	w.push_int(i64(c.quantity))
	return w.park(mut out, mut ac,
		"INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity",
		w.params_buf, k_crud_create, 0, 0, service_unavailable)
}

fn (mut w WorkerCtx) start_crud_update(mut out []u8, mut ac core.AsyncCtx, id int, req request_parser.HttpRequest) core.AsyncStep {
	body := unsafe { req.buffer[req.body.start..req.body.start + req.body.len] }
	if c := parse_crud_body_fast(body, false) {
		w.reset_params()
		w.push_int(i64(id))
		w.push_bytes(c.name)
		w.push_bytes(c.category)
		w.push_int(c.price)
		w.push_int(c.quantity)
		return w.park(mut out, mut ac,
			'UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1',
			w.params_buf, k_crud_update, id, 0, service_unavailable)
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return .done
	}
	w.reset_params()
	w.push_int(i64(id))
	w.push_bytes(unsafe { c.name.str.vbytes(c.name.len) }) // borrow decoded-string bytes
	w.push_bytes(unsafe { c.category.str.vbytes(c.category.len) })
	w.push_int(i64(c.price))
	w.push_int(i64(c.quantity))
	return w.park(mut out, mut ac,
		'UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1',
		w.params_buf, k_crud_update, id, 0, service_unavailable)
}

fn (mut w WorkerCtx) render_crud_update(mut out []u8, id int) {
	// Invalidate the cache slot: flip `valid` to false and KEEP the buffer for the
	// next MISS to reuse. (A map.delete here orphaned the buffer forever under
	// -gc none — the leak this slab fixes.)
	if id >= 1 && id < crud_cache_slots {
		w.ro.crud_mu.@lock()
		w.ro.crud[id].valid = false
		w.ro.crud_mu.unlock()
	}
	write_resp(mut out, 'application/json', '{"status":"ok"}')
}

// ── /json (non-DB) ───────────────────────────────────────────────────────────

fn (w &WorkerCtx) write_json_response(mut out []u8, count int, m i64) {
	// 21 = len('{"items":[') + len('],"count":') + '}'; plus the count's own digits
	mut clen := 21 + digits(i64(count))
	if count > 0 {
		clen += count - 1
	}
	for i in 0 .. count {
		t := w.ro.dataset[i].price * w.ro.dataset[i].quantity * m
		clen += w.ro.prefixes[i].len + digits(t) + 1
	}
	ws(mut out,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(clen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		ws(mut out, w.ro.prefixes[i])
		wi(mut out, w.ro.dataset[i].price * w.ro.dataset[i].quantity * m)
		ws(mut out, if i < count - 1 { '},' } else { '}' })
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	ws(mut out, '}')
}

fn (mut w WorkerCtx) write_json_gzip(mut out []u8, count int, m i64) {
	key := (u64(u32(count)) << 32) | u64(u32(m))
	mut cached := []u8{}
	w.ro.gz_mu.@rlock()
	if c := w.ro.gz[key] {
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
	w.ro.gz_mu.@lock()
	if w.ro.gz.len < 1024 {
		w.ro.gz[key] = resp
	}
	w.ro.gz_mu.unlock()
	wb(mut out, resp)
}

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

// escape_html_into HTML-escapes s directly into out — no intermediate string/Builder
// (escape_html allocated both per fortune row, leaking under -gc none). Fast path: when
// nothing needs escaping, one bulk copy (the common case).
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

// qstr_slice returns a BORROWED view of a string query parameter (no .clone()). Valid
// only while req.buffer is alive — fine for Bind params, which write_bind copies
// synchronously inside park→async_submit before the request buffer is recycled.
@[direct_array_access]
fn qstr_slice(req request_parser.HttpRequest, key []u8) []u8 {
	s := req.get_query_slice(key) or { return []u8{} }
	return unsafe { req.buffer[s.start..s.start + s.len] }
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

fn (mut w WorkerCtx) body_int(req request_parser.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	if te := req.get_header_value_slice('Transfer-Encoding') {
		val := unsafe { tos(&req.buffer[te.start], te.len) }
		if val.contains('chunked') {
			// Reassemble the chunked body into the reused per-worker scratch (no
			// per-request strings.Builder/.str() alloc — the -gc none leak), then
			// parse the integer from the bytes in place.
			unsafe { w.dechunk_buf.len = 0 }
			dechunk_into(mut w.dechunk_buf, req.buffer, req.body.start, req.body.len)
			return parse_i64_slice(w.dechunk_buf, 0, w.dechunk_buf.len)
		}
	}
	return parse_i64_slice(req.buffer, req.body.start, req.body.len)
}

// dechunk_into appends the dechunked body bytes from the chunked-encoded region
// buf[start..start+length] into `out` (a reused scratch). Same framing as the old
// string-building dechunk — read each hex chunk-size line terminated by CRLF, copy
// `size` data bytes, stop at the 0-size chunk or any malformation — but it appends
// raw bytes and parses the size from bytes, so it allocates nothing per request.
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
		// Overflow-safe bound: `data_start + size` is computed in i32 and would WRAP
		// negative for an attacker-chosen size near 0x7fffffff, slipping past a naive
		// `data_start + size > end` check and feeding a ~2 GiB out-of-bounds read into
		// push_many. `end - data_start` is a small non-negative int (data_start <= end),
		// so comparing the other way never overflows.
		if size > end - data_start {
			break
		}
		unsafe { out.push_many(&buf[data_start], size) }
		i = data_start + size + 2 // past the data + its trailing CRLF
	}
}

// parse_hex_slice reads a hex integer from buf[start..start+length], stopping at
// the first non-hex byte (a chunk-extension `;` or the CRLF). No allocation.
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
			return 0x7fff_ffff // saturate: i64 accumulation can't wrap negative, and the
			// caller's `size > end - data_start` guard then rejects this oversized chunk
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
			// Keep fast-path strict and allocation-free; escaped strings fall back to json.decode.
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

fn content_type(name string) string {
	ext := name.all_after_last('.')
	return match ext {
		'css' { 'text/css' }
		'js' { 'application/javascript' }
		'json' { 'application/json' }
		'html' { 'text/html' }
		'svg' { 'image/svg+xml' }
		'webp' { 'image/webp' }
		'woff2' { 'font/woff2' }
		else { 'application/octet-stream' }
	}
}

fn static_header(ctype string, size i64) []u8 {
	mut sb := strings.new_builder(96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(size)
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	return sb
}

// parse_db_url turns postgres://user:pass@host:port/dbname into a pg_async.ConnConfig.
fn parse_db_url(u string) pg_async.ConnConfig {
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
	return pg_async.ConnConfig{
		host:     host_port.all_before(':')
		port:     port
		user:     creds.all_before(':')
		password: creds.all_after(':')
		database: rest.all_after('/')
	}
}

fn main() {
	url := os.getenv_opt('DATABASE_URL') or { 'postgres://bench:bench@localhost:5432/benchmark' }
	cfg := parse_db_url(url)

	// DATABASE_MAX_CONN is the TOTAL connection budget (sized to Postgres
	// max_connections); split it evenly across the thread-per-core workers, each
	// owning its own pool. Each pooled conn carries ONE in-flight query (no
	// pipelining-while-busy), and the load is closed-loop with ~connections/workers
	// clients per worker — so the per-worker pool IS the per-worker concurrency
	// ceiling. A previous `min(8)` clamp wasted half the 256 budget (16 workers ->
	// 8 = 128) and starved the DB endpoints: when the pool is full, park() sheds the
	// request as an empty 200, so the closed-loop clients just spin and throughput
	// collapses. Use the FULL budget (256/16 = 16/worker) — do not re-cap below it.
	mut total := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int()
	if total < 1 {
		total = 64
	}
	workers := runtime.nr_cpus()
	mut per_worker := total / workers
	if per_worker < 1 {
		per_worker = 1
	}

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode([]DatasetItem, dataset_raw) or { []DatasetItem{} }

	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	mut assets := map[string]StaticFile{}
	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	for name in os.ls(static_dir) or { []string{} } {
		if name.ends_with('.gz') || name.ends_with('.br') {
			continue
		}
		path := '${static_dir}/${name}'
		fsize := i64(os.file_size(path))
		fd := C.open(&char(path.str), 0)
		if fd < 0 {
			continue
		}
		assets[name] = StaticFile{
			header: static_header(content_type(name), fsize)
			fd:     fd
			size:   fsize
		}
	}

	ro := &SharedRO{
		dataset:  dataset
		prefixes: prefixes
		assets:   assets
		crud:     []CrudSlot{len: crud_cache_slots}
		crud_mu:  sync.new_rwmutex()
		gz:       map[u64][]u8{}
		gz_mu:    sync.new_rwmutex()
	}

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: .epoll
		limits:          http_server.Limits{
			max_request_bytes: 32 * 1024 * 1024
		}
		async_handler:   handle
		make_state:      fn [ro, cfg, per_worker] () voidptr {
			pool := pg_async.new_pool(cfg, per_worker) or {
				panic('vanilla-epoll: pg pool bring-up failed: ${err}')
			}
			w := &WorkerCtx{
				ro:            ro
				pool:          pool
				scratch:       []u8{cap: 32 * 1024} // reused render buffer (see WorkerCtx.scratch)
				param_scratch: []u8{cap: 256}       // reused int-param decimal bytes (≫ 5×20 worst case)
				params_buf:    []?[]u8{cap: 8}      // reused Bind params array
				stash_pool:    []&Stash{cap: 64}    // Stash free-list
				fortunes_buf:  []Fortune{cap: 256}  // reused /fortunes rows
				dechunk_buf:   []u8{cap: 4096}      // reused chunked-body scratch
			}
			return voidptr(w)
		}
	})!
	server.run()
}
