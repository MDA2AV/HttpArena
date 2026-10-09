module main

// app.v: what each HttpArena endpoint does once a request has been routed to
// it. vanilla-router and vanilla-veb_like ship this file unchanged; only
// main.v, which routes the requests and starts the two listeners, differs.
//
// The binary is built with `-gc none` (vanilla's production build), so nothing
// below allocates per request: responses are appended into the server-owned
// `out`, and bodies that have to be measured before their headers are written
// (JSON, HTML, gzip) are built in per-worker buffers that are reused.
import vanilla.core
import vanilla.http1_1.request_parser { HttpRequest }
import vanilla.pg_async
import vanilla.static_assets
import vanilla.tls
import os
import time
import x.json2

#flag -ldeflate
#include <libdeflate.h>

struct C.libdeflate_compressor {}

fn C.libdeflate_alloc_compressor(compression_level int) &C.libdeflate_compressor
fn C.libdeflate_gzip_compress(c &C.libdeflate_compressor, input voidptr, in_nbytes usize, output voidptr, out_nbytes_avail usize) usize

#include <sys/timerfd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int
fn C.qsort(base voidptr, nmemb usize, size usize, compar voidptr)

struct Rating {
	score i64
	count i64
}

// DatasetItem is one item of /data/dataset.json.
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

// Shared is the read-only, process-wide data every worker of both listeners
// reads without a lock.
@[heap]
struct Shared {
	dataset []DatasetItem
	assets  static_assets.AssetServer // /static/*: br/gz negotiation, follows the disk
}

// Worker is one worker thread's state, created by make_state and handed to
// every handler as `worker_state`. A worker serves one request at a time, so
// its buffers are reused without a lock.
struct Worker {
mut:
	data &Shared = unsafe { nil }
	// pool is this worker's own async Postgres pool (nil on the TLS listener,
	// which serves no database route).
	pool &pg_async.PgPool = unsafe { nil }
	// body holds a JSON or HTML body while it is built, so its length is known
	// before the headers are written. Reset per response, never shrunk.
	body []u8
	// gz receives the gzip-compressed body; gzip is the compressor writing it.
	gz   []u8
	gzip &C.libdeflate_compressor = unsafe { nil }
	// dechunked holds a chunked request body, reassembled.
	dechunked []u8
	// params / param_digits are the bind parameters of the next query: integers
	// are written as decimal into param_digits and params points at them.
	// param_digits never grows past its initial capacity (3 parameters of at
	// most 20 digits), so the views stay valid until async_submit copies them.
	params       []?[]u8
	param_digits []u8
	parked       []&Parked // free-list of Parked records
	fortunes     []Fortune
	timer_fds    []int // idle one-shot timerfds for /delay
}

fn new_worker(data &Shared, pool &pg_async.PgPool) &Worker {
	return &Worker{
		data:         data
		pool:         unsafe { pool } // new_pool's result, on the heap
		body:         []u8{cap: 32 * 1024}
		gz:           []u8{len: gz_capacity}
		gzip:         C.libdeflate_alloc_compressor(gzip_level)
		dechunked:    []u8{cap: 16 * 1024}
		params:       []?[]u8{cap: 4}
		param_digits: []u8{cap: 64}
		parked:       []&Parked{cap: 64}
		fortunes:     []Fortune{cap: 256}
		timer_fds:    []int{cap: 64}
	}
}

// ── responses ────────────────────────────────────────────────────────────────

const ok_text = 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: text/plain\r\nContent-Length: '
const keep_alive_body = '\r\nConnection: keep-alive\r\n\r\n'
const pipeline_response = 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'
const not_found_response = 'HTTP/1.1 404 Not Found\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const unavailable_response = 'HTTP/1.1 503 Service Unavailable\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

// wi appends the decimal digits of n.
@[direct_array_access]
fn wi(mut out []u8, n i64) {
	mut tmp := [20]u8{}
	mut x := if n < 0 { u64(0) - u64(n) } else { u64(n) }
	mut i := 20
	for {
		i--
		tmp[i] = u8(`0`) + u8(x % 10)
		x /= 10
		if x == 0 {
			break
		}
	}
	if n < 0 {
		i--
		tmp[i] = `-`
	}
	unsafe { out.push_many(&tmp[i], 20 - i) }
}

fn decimal_len(n i64) int {
	mut x := if n < 0 { u64(0) - u64(n) } else { u64(n) }
	mut d := if n < 0 { 2 } else { 1 }
	for x >= 10 {
		x /= 10
		d++
	}
	return d
}

@[inline]
fn wb(mut out []u8, b []u8) {
	unsafe { out.push_many(b.data, b.len) }
}

// emit appends a 200 response with the given body.
fn emit(mut out []u8, content_type string, body []u8) {
	core.append_str(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	core.append_str(mut out, content_type)
	core.append_str(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	core.append_str(mut out, keep_alive_body)
	wb(mut out, body)
}

// emit_str appends a 200 response whose body is a constant.
fn emit_str(mut out []u8, content_type string, body string) {
	emit(mut out, content_type, unsafe { body.str.vbytes(body.len) })
}

// emit_int appends a 200 text/plain response whose body is n.
fn emit_int(mut out []u8, n i64) {
	core.append_str(mut out, ok_text)
	wi(mut out, i64(decimal_len(n)))
	core.append_str(mut out, keep_alive_body)
	wi(mut out, n)
}

// step_for is the step that ends a synchronous route: .close when the request
// carries the `close` connection option (RFC 9112 §9.6), .done otherwise.
@[inline]
fn step_for(req HttpRequest) core.Step {
	return if has_close_option(req) { core.Step.close } else { core.Step.done }
}

// ── GET|POST /baseline11, GET /pipeline ──────────────────────────────────────

// baseline answers a + b, plus the integer body of a POST.
fn baseline(mut w Worker, req HttpRequest, mut out []u8) core.Step {
	mut sum := query_int(req, 'a') + query_int(req, 'b')
	if req.body.len > 0 {
		sum += body_int(mut w, req)
	}
	emit_int(mut out, sum)
	return step_for(req)
}

fn pipeline(req HttpRequest, mut out []u8) core.Step {
	core.append_str(mut out, pipeline_response)
	return step_for(req)
}

// ── GET /json/{count}?m=N ────────────────────────────────────────────────────

// gzip_level is libdeflate's compression level for /json. json-comp scores
// throughput times the square of the compression ratio, and compressing is
// most of the request's CPU: on the 50-item body, level 1 takes 15 us for
// 1708 bytes, level 6 38 us for 1478 and level 9 56 us for 1459, so level 1
// serves about 2.5 times as many requests for 15% more bytes. (Brotli is
// slower than this at every size: quality 2 takes 27 us for 1553 bytes.)
const gzip_level = 1
// gz_capacity bounds the compressed /json body: 50 items serialize to ~11 KiB,
// and gzip output is never much larger than its input.
const gz_capacity = 64 * 1024

// json_items serializes the first `count` dataset items with total = price *
// quantity * m, gzip-compressed when the client accepts gzip. Both happen per
// request, from the dataset's fields.
fn json_items(mut w Worker, req HttpRequest, count_segment string, mut out []u8) core.Step {
	count := clamp_count(parse_uint(count_segment), w.data.dataset.len)
	mut m := query_int(req, 'm')
	if m == 0 {
		m = 1
	}
	unsafe {
		w.body.len = 0
	}
	write_items(mut w.body, w.data.dataset, count, m)
	if accepts_gzip(req) {
		n := int(C.libdeflate_gzip_compress(w.gzip, w.body.data, usize(w.body.len), w.gz.data,
			usize(w.gz.len)))
		if n > 0 {
			core.append_str(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nVary: Accept-Encoding\r\nContent-Length: ')
			wi(mut out, i64(n))
			core.append_str(mut out, keep_alive_body)
			unsafe { out.push_many(w.gz.data, n) }
			return step_for(req)
		}
	}
	core.append_str(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nVary: Accept-Encoding\r\nContent-Length: ')
	wi(mut out, i64(w.body.len))
	core.append_str(mut out, keep_alive_body)
	wb(mut out, w.body)
	return step_for(req)
}

fn write_items(mut b []u8, dataset []DatasetItem, count int, m i64) {
	core.append_str(mut b, '{"items":[')
	for i in 0 .. count {
		it := unsafe { &dataset[i] }
		if i > 0 {
			core.append_str(mut b, ',')
		}
		core.append_str(mut b, '{"id":')
		wi(mut b, it.id)
		core.append_str(mut b, ',"name":"')
		write_json_string(mut b, it.name)
		core.append_str(mut b, '","category":"')
		write_json_string(mut b, it.category)
		core.append_str(mut b, '","price":')
		wi(mut b, it.price)
		core.append_str(mut b, ',"quantity":')
		wi(mut b, it.quantity)
		core.append_str(mut b, if it.active {
			',"active":true,"tags":['
		} else {
			',"active":false,"tags":['
		})
		for j, tag in it.tags {
			core.append_str(mut b, if j > 0 { ',"' } else { '"' })
			write_json_string(mut b, tag)
			core.append_str(mut b, '"')
		}
		core.append_str(mut b, '],"rating":{"score":')
		wi(mut b, it.rating.score)
		core.append_str(mut b, ',"count":')
		wi(mut b, it.rating.count)
		core.append_str(mut b, '},"total":')
		wi(mut b, it.price * it.quantity * m)
		core.append_str(mut b, '}')
	}
	core.append_str(mut b, '],"count":')
	wi(mut b, i64(count))
	core.append_str(mut b, '}')
}

// write_json_string appends s JSON-escaped, without the quotes.
@[direct_array_access]
fn write_json_string(mut b []u8, s string) {
	mut from := 0
	for i in 0 .. s.len {
		c := s[i]
		if c != `"` && c != `\\` && c >= 0x20 {
			continue
		}
		unsafe { b.push_many(s.str + from, i - from) }
		match c {
			`"` { core.append_str(mut b, '\\"') }
			`\\` { core.append_str(mut b, '\\\\') }
			`\n` { core.append_str(mut b, '\\n') }
			`\r` { core.append_str(mut b, '\\r') }
			`\t` { core.append_str(mut b, '\\t') }
			else { write_json_control(mut b, c) }
		}
		from = i + 1
	}
	unsafe { b.push_many(s.str + from, s.len - from) }
}

fn write_json_control(mut b []u8, c u8) {
	hex := '0123456789abcdef'
	core.append_str(mut b, '\\u00')
	unsafe {
		b.push_many(hex.str + (c >> 4), 1)
		b.push_many(hex.str + (c & 15), 1)
	}
}

// ── POST /echo ───────────────────────────────────────────────────────────────

// echo answers with the request body, byte for byte: the bytes that arrived,
// dechunked when the request is chunked, never sized from Content-Length.
fn echo(mut w Worker, req HttpRequest, mut out []u8) core.Step {
	if is_chunked(req) {
		unsafe {
			w.dechunked.len = 0
		}
		dechunk_into(mut w.dechunked, req.buffer, req.body.start, req.body.len)
		emit(mut out, 'application/octet-stream', w.dechunked)
	} else {
		emit(mut out, 'application/octet-stream', unsafe { (&req.buffer[req.body.start]).vbytes(req.body.len) })
	}
	return step_for(req)
}

// ── GET /static/* ────────────────────────────────────────────────────────────

fn static_file(w &Worker, req HttpRequest, mut out []u8) core.Step {
	w.data.assets.respond_req_into(&req, mut out)
	return step_for(req)
}

// ── GET /async-db, GET /fortunes: parked on the worker's Postgres pool ───────

// Parked is what a request parked on a Postgres connection needs when its
// reply arrives (the request buffer is reused meanwhile).
struct Parked {
mut:
	kind  QueryKind
	conn  int
	close bool
}

enum QueryKind as u8 {
	async_db
	fortunes
}

const async_db_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3'
const fortunes_sql = 'SELECT id, message FROM fortune'
const async_db_empty = '{"items":[],"count":0}'
const fortunes_empty = '<!doctype html><html><body><table></table></body></html>'

fn async_db(mut w Worker, req HttpRequest, mut out []u8, mut event_loop core.EventLoop) core.Step {
	mut limit := query_int(req, 'limit')
	if limit < 1 {
		limit = 1
	}
	if limit > 50 {
		limit = 50
	}
	unsafe {
		w.params.len = 0
		w.param_digits.len = 0
	}
	w.push_param(query_int(req, 'min'))
	w.push_param(query_int(req, 'max'))
	w.push_param(limit)
	return w.park(mut out, mut event_loop, .async_db, async_db_sql, has_close_option(req))
}

fn fortunes(mut w Worker, req HttpRequest, mut out []u8, mut event_loop core.EventLoop) core.Step {
	unsafe {
		w.params.len = 0
	}
	return w.park(mut out, mut event_loop, .fortunes, fortunes_sql, has_close_option(req))
}

fn (mut w Worker) push_param(n i64) {
	start := w.param_digits.len
	wi(mut w.param_digits, n)
	w.params << ?[]u8(unsafe { (&w.param_digits[start]).vbytes(w.param_digits.len - start) })
}

// park submits the query on the least-loaded pooled connection and suspends
// the request until its reply arrives. A saturated pool sheds the request
// with an empty result rather than queueing it without bound.
fn (mut w Worker) park(mut out []u8, mut event_loop core.EventLoop, kind QueryKind, query string, close bool) core.Step {
	idx := w.pool.acquire_pipelined() or { return shed(mut out, kind) }
	mut c := w.pool.conn(idx)
	if !c.async_submit(query, w.params) {
		return shed(mut out, kind)
	}
	c.async_flush() or { return shed(mut out, kind) }
	mut p := &Parked(unsafe { nil })
	if w.parked.len > 0 {
		p = w.parked.pop()
	} else {
		p = &Parked{}
	}
	p.kind = kind
	p.conn = idx
	p.close = close
	// The fd is a pooled connection: if the client leaves mid-query, the runtime
	// drains the orphaned reply and keeps the connection open.
	event_loop.watch_fd_persistent(w.pool.fd(idx), .readable, on_db_reply, voidptr(p))
	return .suspend
}

fn shed(mut out []u8, kind QueryKind) core.Step {
	match kind {
		.async_db { emit_str(mut out, 'application/json', async_db_empty) }
		.fortunes { emit_str(mut out, 'text/html; charset=utf-8', fortunes_empty) }
	}
	return .done
}

// on_db_reply resumes a parked request when its connection is readable.
fn on_db_reply(mut out []u8, _ int, _ bool, payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	p := unsafe { &Parked(payload) }
	mut c := w.pool.conn(p.conn)
	poll := c.async_on_readable() or {
		shed(mut out, p.kind)
		return w.unpark(p)
	}
	if !poll.ready {
		// More of the reply is still to come: wait again (p stays the payload).
		event_loop.watch_fd_persistent(w.pool.fd(p.conn), .readable, on_db_reply, payload)
		return .suspend
	}
	match p.kind {
		.async_db { w.render_items(mut out, poll.result) }
		.fortunes { w.render_fortunes(mut out, poll.result) }
	}
	return w.unpark(p)
}

fn (mut w Worker) unpark(p &Parked) core.Step {
	step := if p.close { core.Step.close } else { core.Step.done }
	if w.parked.len < 64 {
		w.parked << p
	}
	return step
}

fn (mut w Worker) render_items(mut out []u8, res pg_async.Result) {
	unsafe {
		w.body.len = 0
	}
	core.append_str(mut w.body, '{"items":[')
	mut rows := res.rows()
	mut count := 0
	for {
		row := rows.next() or { break }
		if count > 0 {
			core.append_str(mut w.body, ',')
		}
		core.append_str(mut w.body, '{"id":')
		wi(mut w.body, i64(row.int4(0) or { 0 }))
		core.append_str(mut w.body, ',"name":"')
		write_json_bytes(mut w.body, row.text(1) or { []u8{} })
		core.append_str(mut w.body, '","category":"')
		write_json_bytes(mut w.body, row.text(2) or { []u8{} })
		core.append_str(mut w.body, '","price":')
		wi(mut w.body, i64(row.int4(3) or { 0 }))
		core.append_str(mut w.body, ',"quantity":')
		wi(mut w.body, i64(row.int4(4) or { 0 }))
		core.append_str(mut w.body, if row.boolean(5) or { false } {
			',"active":true,"tags":'
		} else {
			',"active":false,"tags":'
		})
		// tags is JSONB, read in binary: a version byte, then JSON text.
		tags := pg_async.jsonb_text(row.text(6) or { []u8{} })
		if tags.len > 0 {
			wb(mut w.body, tags)
		} else {
			core.append_str(mut w.body, '[]')
		}
		core.append_str(mut w.body, ',"rating":{"score":')
		wi(mut w.body, i64(row.int4(7) or { 0 }))
		core.append_str(mut w.body, ',"count":')
		wi(mut w.body, i64(row.int4(8) or { 0 }))
		core.append_str(mut w.body, '}}')
		count++
	}
	core.append_str(mut w.body, '],"count":')
	wi(mut w.body, i64(count))
	core.append_str(mut w.body, '}')
	emit(mut out, 'application/json', w.body)
}

@[inline]
fn write_json_bytes(mut b []u8, s []u8) {
	write_json_string(mut b, unsafe { tos(s.data, s.len) })
}

// Fortune is one row; message is a view of the reply, valid while it renders.
struct Fortune {
	id      int
	message []u8
}

const runtime_fortune = 'Additional fortune added at request time.'

// render_fortunes adds the runtime row, sorts by message and renders the page
// with every message HTML-escaped, per request.
fn (mut w Worker) render_fortunes(mut out []u8, res pg_async.Result) {
	unsafe {
		w.fortunes.len = 0
	}
	mut rows := res.rows()
	for {
		row := rows.next() or { break }
		w.fortunes << Fortune{
			id:      row.int4(0) or { 0 }
			message: row.text(1) or { []u8{} }
		}
	}
	w.fortunes << Fortune{
		id:      0
		message: unsafe { runtime_fortune.str.vbytes(runtime_fortune.len) }
	}
	// libc qsort: its scratch, if any, is malloc'd and freed inside the call.
	C.qsort(w.fortunes.data, usize(w.fortunes.len), sizeof(Fortune), voidptr(compare_fortunes))
	unsafe {
		w.body.len = 0
	}
	core.append_str(mut w.body, '<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in w.fortunes {
		core.append_str(mut w.body, '<tr><td>')
		wi(mut w.body, i64(f.id))
		core.append_str(mut w.body, '</td><td>')
		write_html_escaped(mut w.body, f.message)
		core.append_str(mut w.body, '</td></tr>')
	}
	core.append_str(mut w.body, '</table></body></html>')
	emit(mut out, 'text/html; charset=utf-8', w.body)
}

fn compare_fortunes(a &Fortune, b &Fortune) int {
	n := if a.message.len < b.message.len { a.message.len } else { b.message.len }
	r := unsafe { C.memcmp(a.message.data, b.message.data, n) }
	if r != 0 {
		return r
	}
	return a.message.len - b.message.len
}

@[direct_array_access]
fn write_html_escaped(mut b []u8, s []u8) {
	mut from := 0
	for i in 0 .. s.len {
		c := s[i]
		if c != `&` && c != `<` && c != `>` && c != `"` && c != `'` {
			continue
		}
		if i > from {
			unsafe { b.push_many(&s[from], i - from) }
		}
		core.append_str(mut b, match c {
			`&` { '&amp;' }
			`<` { '&lt;' }
			`>` { '&gt;' }
			`"` { '&quot;' }
			else { '&#39;' }
		})
		from = i + 1
	}
	if from < s.len {
		unsafe { b.push_many(&s[from], s.len - from) }
	}
}

// ── GET /delay/{ms}: parked on a one-shot timerfd ────────────────────────────

// close_flag marks, in the watch payload, a /delay request that carried the
// `close` connection option; the rest of the payload is the delay in ms.
const close_flag = u64(1) << 62
const timer_pool_max = 4096

// delay answers with {ms} once that many milliseconds have passed, without
// holding the worker: the request waits on a timerfd from the worker's
// free-list while the worker serves its other connections.
fn delay(mut w Worker, req HttpRequest, ms_segment string, mut out []u8, mut event_loop core.EventLoop) core.Step {
	ms := parse_uint(ms_segment)
	if ms < 0 || ms > 3_600_000 {
		core.append_str(mut out, not_found_response)
		return step_for(req)
	}
	if ms == 0 {
		emit_int(mut out, 0)
		return step_for(req)
	}
	mut tfd := -1
	if w.timer_fds.len > 0 {
		tfd = w.timer_fds.pop()
	} else {
		tfd = C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
		if tfd < 0 {
			core.append_str(mut out, unavailable_response)
			return .done
		}
	}
	// struct itimerspec { it_interval = 0 (one-shot), it_value = ms }
	mut spec := [4]i64{}
	spec[2] = ms / 1000
	spec[3] = (ms % 1000) * 1_000_000
	if C.timerfd_settime(tfd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil }) != 0 {
		C.close(tfd)
		core.append_str(mut out, unavailable_response)
		return .done
	}
	mut payload := u64(ms)
	if has_close_option(req) {
		payload |= close_flag
	}
	event_loop.watch_fd(tfd, .readable, on_delay_elapsed, voidptr(usize(payload)))
	return .suspend
}

// on_delay_elapsed answers once the timerfd reports an expiration; a wake-up
// without one waits again, so no response leaves before its delay.
fn on_delay_elapsed(mut out []u8, tfd int, fd_error bool, payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	mut expirations := u64(0)
	if C.read(tfd, &expirations, 8) != 8 {
		if fd_error {
			C.close(tfd)
			core.append_str(mut out, unavailable_response)
			return .done
		}
		event_loop.watch_fd(tfd, .readable, on_delay_elapsed, payload)
		return .suspend
	}
	if w.timer_fds.len < timer_pool_max {
		w.timer_fds << tfd
	} else {
		C.close(tfd)
	}
	p := u64(usize(payload))
	emit_int(mut out, i64(p & ~close_flag))
	return if p & close_flag != 0 { core.Step.close } else { core.Step.done }
}

// ── request helpers ──────────────────────────────────────────────────────────

// query_int parses the integer query parameter `key` in place (0 when absent).
fn query_int(req HttpRequest, key string) i64 {
	s := req.get_query_slice(unsafe { key.str.vbytes(key.len) }) or { return 0 }
	return parse_int(req.buffer, s.start, s.len)
}

// parse_int reads a decimal integer at buf[start..start+len], with an optional
// leading '-', stopping at the first other byte.
@[direct_array_access]
fn parse_int(buf []u8, start int, len int) i64 {
	mut n := i64(0)
	mut neg := false
	for i in start .. start + len {
		c := buf[i]
		if i == start && c == `-` {
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

// parse_uint reads a path segment made only of 1-9 decimal digits; anything
// else is -1.
@[direct_array_access]
fn parse_uint(s string) i64 {
	if s.len == 0 || s.len > 9 {
		return -1
	}
	mut n := i64(0)
	for i in 0 .. s.len {
		c := s[i]
		if c < `0` || c > `9` {
			return -1
		}
		n = n * 10 + i64(c - `0`)
	}
	return n
}

fn clamp_count(n i64, max int) int {
	if n < 0 {
		return 0
	}
	return if n > max { max } else { int(n) }
}

fn body_int(mut w Worker, req HttpRequest) i64 {
	if is_chunked(req) {
		unsafe {
			w.dechunked.len = 0
		}
		dechunk_into(mut w.dechunked, req.buffer, req.body.start, req.body.len)
		return parse_int(w.dechunked, 0, w.dechunked.len)
	}
	return parse_int(req.buffer, req.body.start, req.body.len)
}

// is_chunked reports whether the request body is chunked: the server frames a
// chunked request but hands the body over with its framing.
fn is_chunked(req HttpRequest) bool {
	te := req.get_header_value_slice('Transfer-Encoding') or { return false }
	return has_token(req.buffer, te.start, te.len, 'chunked')
}

// has_close_option reports whether the Connection header lists `close`.
fn has_close_option(req HttpRequest) bool {
	c := req.get_header_value_slice('Connection') or { return false }
	return has_token(req.buffer, c.start, c.len, 'close')
}

// accepts_gzip reports whether Accept-Encoding lists gzip, or `*`, with a
// non-zero weight (RFC 9110 §12.5.3).
@[direct_array_access]
fn accepts_gzip(req HttpRequest) bool {
	ae := req.get_header_value_slice('Accept-Encoding') or { return false }
	buf := req.buffer
	end := ae.start + ae.len
	mut i := ae.start
	for i < end {
		for i < end && (buf[i] == ` ` || buf[i] == `\t` || buf[i] == `,`) {
			i++
		}
		name := i
		for i < end && buf[i] != `,` && buf[i] != `;` && buf[i] != ` ` && buf[i] != `\t` {
			i++
		}
		name_len := i - name
		mut zero := false
		for i < end && buf[i] != `,` {
			// a `q=0`, `q=0.0`, ... parameter refuses the coding
			if (buf[i] == `q` || buf[i] == `Q`) && i + 2 < end && buf[i + 1] == `=` && buf[i + 2] == `0` {
				zero = true
				mut k := i + 3
				if k < end && buf[k] == `.` {
					k++
					for k < end && buf[k] == `0` {
						k++
					}
				}
				if k < end && buf[k] >= `1` && buf[k] <= `9` {
					zero = false
				}
			}
			i++
		}
		if (name_len == 4 && same_ascii_ci(buf, name, 'gzip'))
			|| (name_len == 1 && buf[name] == `*`) {
			return !zero
		}
	}
	return false
}

// has_token reports whether the comma-separated list at buf[start..start+len]
// holds `token`, compared case-insensitively.
@[direct_array_access]
fn has_token(buf []u8, start int, len int, token string) bool {
	end := start + len
	mut i := start
	for i + token.len <= end {
		if same_ascii_ci(buf, i, token) {
			before := i == start || is_list_separator(buf[i - 1])
			after := i + token.len == end || is_list_separator(buf[i + token.len])
			if before && after {
				return true
			}
		}
		i++
	}
	return false
}

@[inline]
fn is_list_separator(c u8) bool {
	return c == `,` || c == ` ` || c == `\t` || c == `;`
}

@[direct_array_access]
fn same_ascii_ci(buf []u8, at int, lower string) bool {
	for k in 0 .. lower.len {
		if buf[at + k] | 0x20 != lower[k] {
			return false
		}
	}
	return true
}

// dechunk_into appends the data of the chunked body at buf[start..start+len]
// to out, stopping at the last chunk or at anything malformed.
@[direct_array_access]
fn dechunk_into(mut out []u8, buf []u8, start int, len int) {
	end := start + len
	mut i := start
	for i < end {
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
		size := parse_chunk_size(buf, i, nl)
		data := nl + 2
		// `size > end - data` cannot overflow, unlike `data + size > end`
		if size <= 0 || size > end - data {
			break
		}
		unsafe { out.push_many(&buf[data], size) }
		i = data + size + 2
	}
}

// parse_chunk_size reads the hex chunk size at buf[from..to], up to a chunk
// extension; it saturates rather than overflow.
@[direct_array_access]
fn parse_chunk_size(buf []u8, from int, to int) int {
	mut n := i64(0)
	for k in from .. to {
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
			return 0x7fff_ffff
		}
	}
	return int(n)
}

// ── startup ──────────────────────────────────────────────────────────────────

fn load_shared() &Shared {
	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	raw := os.read_file(dataset_path) or { '[]' }
	dataset := json2.decode[[]DatasetItem](raw) or { panic('dataset: ${err}') }
	// /static/*: the library's static file server. It negotiates the .br/.gz
	// siblings on disk per Accept-Encoding, re-checks every representation
	// against its file (one stat(2) per 100 ms window, so a replaced file is
	// served at once), and sends bodies of 16 KiB or more with sendfile(2).
	assets := static_assets.new(static_assets.Config{
		root:               os.getenv_opt('STATIC_DIR') or { '/data/static' }
		url_prefix:         '/static/'
		spa_fallback:       ''
		sendfile_min_bytes: 16 * 1024
		memory_fallback:    true
		follow_disk:        true
		revalidate_ms:      100
	}) or { panic('static_assets: ${err}') }
	return &Shared{
		dataset: dataset
		assets:  assets
	}
}

// parse_db_url reads postgres://user:pass@host:port/dbname.
fn parse_db_url(url string) pg_async.ConnConfig {
	s := if url.contains('://') { url.all_after('://') } else { url }
	creds := s.all_before('@')
	rest := s.all_after('@')
	host_port := rest.all_before('/')
	return pg_async.ConnConfig{
		host:     host_port.all_before(':')
		port:     if host_port.contains(':') { host_port.all_after(':').int() } else { 5432 }
		user:     creds.all_before(':')
		password: creds.all_after(':')
		database: rest.all_after('/')
	}
}

// connect_pool opens a worker's pool, retrying for up to 30 s while Postgres
// still refuses connections (it restarts once after its init scripts).
fn connect_pool(cfg pg_async.ConnConfig, size int) &pg_async.PgPool {
	mut last := ''
	for _ in 0 .. 150 {
		if pool := pg_async.new_pool(cfg, size) {
			return pool
		} else {
			last = err.msg()
		}
		time.sleep(200 * time.millisecond)
	}
	panic('pg pool: ${last}')
}

// pool_size splits DATABASE_MAX_CONN, the total connection budget, across the
// workers.
fn pool_size() int {
	mut total := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int()
	if total < 1 {
		total = 64
	}
	per_worker := total / core.max_thread_pool_size
	return if per_worker < 1 { 1 } else { per_worker }
}

// tls_config reads the certificate the harness mounts at /certs; without one
// (a local run) it self-signs.
fn tls_config() &tls.Config {
	cert_path := os.getenv_opt('TLS_CERT') or { '/certs/server.crt' }
	key_path := os.getenv_opt('TLS_KEY') or { '/certs/server.key' }
	cert := os.read_bytes(cert_path) or {
		eprintln('no TLS certificate at ${cert_path}; self-signing')
		return tls.new_self_signed() or { panic('tls: ${err}') }
	}
	key := os.read_bytes(key_path) or { panic('tls: no key at ${key_path}: ${err}') }
	return tls.new_from_pem(cert, key) or { panic('tls: ${err}') }
}

fn tls_port() int {
	port := (os.getenv_opt('TLS_PORT') or { '8081' }).int()
	return if port > 0 { port } else { 8081 }
}
