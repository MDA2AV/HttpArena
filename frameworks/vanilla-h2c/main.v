module main

// HTTP/2 cleartext (h2c, prior-knowledge) on vanilla's conn-mode seam
// (enghitalo/vanilla#136 + the http2 arm): one epoll engine drives the RFC
// 9113 state machine behind a ConnHandler. Prior-knowledge only — no TLS, no
// h1->h2 Upgrade. An http2 client's first bytes are the connection preface
// `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`; its head parses as an ordinary HTTP/1.1
// request (method PRI, target *), so it reaches `handle`. The handler flips
// the connection into the http2 machine (core.queue_takeover), appends the
// server connection preface (a SETTINGS frame) as its switching response, and
// every later burst — starting with the `SM\r\n\r\n` tail already buffered —
// is fed to h2c_conn instead of the HTTP/1.1 state machine. Requests surface
// only when COMPLETE (END_STREAM), so the app stays a pure function of a whole
// request, the same discipline as the h1 path.
//
// The :8082 listener is h2c-ONLY: a plain HTTP/1.1 request is answered 505 and
// the connection dropped, never a 200. HttpArena's validator asserts this so
// the benchmark can't silently measure h1 throughput on the h2c port.
//
// Routes (the two h2c profiles, plus unary-grpc):
//   GET /baseline2?a=&b=  -> text/plain, the integer sum a+b
//   GET /json/{count}?m=  -> application/json, {"items":[...],"count":N}
//   POST /benchmark.BenchmarkService/GetSum -> gRPC SumReply{result: a+b}
//
// The same handlers also listen on :8080, the port the harness drives unary
// gRPC on (h2c prior-knowledge there too).
// The /json body reuses the vanilla /json profile's shape verbatim: the same
// /data/dataset.json, the same precomputed per-item prefixes, total =
// price*quantity*m. Multi-threaded, SO_REUSEPORT, lock-free, -gc none.
import vanilla.core
import vanilla.server
import vanilla.http2
import vanilla.http1_1.request_parser
import vanilla.http1_1.response
import x.json2 as json
import os

struct Rating {
	score i64
	count i64
}

// DatasetItem mirrors /data/dataset.json.
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

// SharedRO is the process-wide immutable data: the dataset plus the
// precomputed per-item JSON prefix (each item minus its m-dependent total).
// Shared by pointer across every worker via make_state — read-only, no locks.
struct SharedRO {
	dataset  []DatasetItem
	prefixes []string
}

const pri_method = 'PRI'.bytes()
const star_target = '*'.bytes()

// 505: this port speaks h2c (prior-knowledge) only. A genuine HTTP/1.1 request
// is refused, never served a 200 — the benchmark measures h2c or nothing.
const h1_not_supported = 'HTTP/1.1 505 HTTP Version Not Supported\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
// 501: this worker/backend cannot take connections over (queue_takeover is
// false off epoll) — a clear error beats a dead, half-spoken SETTINGS.
const cannot_takeover = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

const baseline2_route = '/baseline2'
const json_route_prefix = '/json/'
const ctype_text = 'text/plain'
const ctype_json = 'application/json'

// ── byte helpers (append-only, no per-request heap allocation) ───────────────

fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wi appends n's decimal digits (itoa into a stack scratch, then push_many).
@[direct_array_access]
fn wi(mut out []u8, n i64) {
	mut tmp := [20]u8{}
	if n == 0 {
		tmp[0] = u8(`0`)
		unsafe { out.push_many(&tmp[0], 1) }
		return
	}
	neg := n < 0
	// Build the magnitude in u64: i64::MIN's negation overflows i64, so derive
	// it as -(n+1)+1 with the +1 in u64.
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

// slice_eq compares a request Slice against a small const byte pattern.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, want []u8) bool {
	if s.len != want.len {
		return false
	}
	for i in 0 .. want.len {
		if buf[s.start + i] != want[i] {
			return false
		}
	}
	return true
}

// parse_u_at reads a non-negative decimal from s[start..], stopping at the
// first non-digit.
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

// q_int reads integer query parameter `key` from a full request-target string
// (e.g. "/baseline2?a=13&b=42"). Returns 0 when the key is absent. It indexes
// into target: slicing substrings (target[a..], query[i..eq] == key) would
// heap-copy each one, allocations per request that -gc none never frees.
@[direct_array_access]
fn q_int(target string, key string) i64 {
	qpos := target.index_u8(`?`)
	if qpos < 0 {
		return 0
	}
	mut i := qpos + 1
	for i < target.len {
		mut eq := i
		for eq < target.len && target[eq] != `=` && target[eq] != `&` {
			eq++
		}
		if eq < target.len && target[eq] == `=` && eq - i == key.len {
			mut same := true
			for k in 0 .. key.len {
				if target[i + k] != key[k] {
					same = false
					break
				}
			}
			if same {
				return parse_u_at(target, eq + 1)
			}
		}
		mut amp := eq
		for amp < target.len && target[amp] != `&` {
			amp++
		}
		i = amp + 1
	}
	return 0
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

// write_json_body appends the /json response BODY (no framing): the vanilla
// /json shape, total = price*quantity*m.
fn write_json_body(ro &SharedRO, mut out []u8, count int, m i64) {
	ws(mut out, '{"items":[')
	for i in 0 .. count {
		ws(mut out, ro.prefixes[i])
		wi(mut out, ro.dataset[i].price * ro.dataset[i].quantity * m)
		ws(mut out, if i < count - 1 { '},' } else { '}' })
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	ws(mut out, '}')
}

// ── HTTP/2 response framing ──────────────────────────────────────────────────

// H2cConn is one flipped connection's state (the takeover_state): the http2
// machine plus the buffers every request on it reuses. Allocated once per
// connection; nothing on the request path allocates (the binary is -gc none,
// where a per-request buffer would never be freed).
struct H2cConn {
mut:
	conn  &http2.ServerConn = unsafe { nil }
	reqs  []http2.Http2Request
	block []u8
	body  []u8
}

// respond appends a 200 HEADERS block (:status + content-type) and the body as
// DATA (END_STREAM on the header frame when the body is empty).
fn respond(mut hc H2cConn, stream_id u32, ctype string, body []u8, mut out []u8) {
	hc.block.clear()
	http2.encode_status(mut hc.block, 200)
	http2.encode_literal(mut hc.block, 'content-type', ctype)
	hc.conn.write_response_headers(mut out, stream_id, hc.block, body.len == 0)
	if body.len > 0 {
		hc.conn.write_response_data(mut out, stream_id, body)
	}
}

// respond_status answers with a bodiless status (400 malformed / 404).
fn respond_status(mut hc H2cConn, stream_id u32, status int, mut out []u8) {
	hc.block.clear()
	http2.encode_status(mut hc.block, status)
	hc.conn.write_response_headers(mut out, stream_id, hc.block, true)
}

// ── unary gRPC: benchmark.BenchmarkService/GetSum ────────────────────────────

const grpc_path = '/benchmark.BenchmarkService/GetSum'

// The fixed header blocks, encoded once: the response head, the OK trailers,
// and the trailers-only answer for a request that is not a valid SumRequest.
const grpc_head_block = grpc_block(200, 'content-type', 'application/grpc')
const grpc_ok_trailers = grpc_block(0, 'grpc-status', '0')
const grpc_invalid = grpc_invalid_block()

fn grpc_block(status int, name string, value string) []u8 {
	mut b := []u8{}
	if status > 0 {
		http2.encode_status(mut b, status)
	}
	http2.encode_literal(mut b, name, value)
	return b
}

fn grpc_invalid_block() []u8 {
	mut b := grpc_block(200, 'content-type', 'application/grpc')
	http2.encode_literal(mut b, 'grpc-status', '3') // INVALID_ARGUMENT
	return b
}

// read_varint decodes a protobuf varint at buf[pos..end]: (value, next pos),
// or next pos -1 when it is truncated or longer than 10 bytes.
@[direct_array_access]
fn read_varint(buf []u8, pos int, end int) (u64, int) {
	mut v := u64(0)
	mut shift := u32(0)
	mut i := pos
	for i < end && shift < 70 {
		c := buf[i]
		i++
		v |= u64(c & 0x7f) << shift
		if c & 0x80 == 0 {
			return v, i
		}
		shift += 7
	}
	return 0, -1
}

// decode_sum_request parses a length-prefixed SumRequest (field 1 `a`, field 2
// `b`, both int32 varints) out of a gRPC request body, skipping unknown fields
// of every wire type. ok=false for a compressed frame, a length that does not
// match the body, or a malformed message.
@[direct_array_access]
fn decode_sum_request(body []u8) (i64, i64, bool) {
	if body.len < 5 || body[0] != 0 {
		return 0, 0, false
	}
	n := int(u32(body[1]) << 24 | u32(body[2]) << 16 | u32(body[3]) << 8 | u32(body[4]))
	if n != body.len - 5 {
		return 0, 0, false
	}
	end := body.len
	mut a := i64(0)
	mut b := i64(0)
	mut i := 5
	for i < end {
		key, next := read_varint(body, i, end)
		if next < 0 {
			return 0, 0, false
		}
		i = next
		match key & 7 {
			0 {
				v, after := read_varint(body, i, end)
				if after < 0 {
					return 0, 0, false
				}
				i = after
				// int32 is sign-extended to 64 bits on the wire
				if key >> 3 == 1 {
					a = i64(i32(u32(v)))
				} else if key >> 3 == 2 {
					b = i64(i32(u32(v)))
				}
			}
			1 {
				i += 8
			}
			2 {
				l, after := read_varint(body, i, end)
				if after < 0 {
					return 0, 0, false
				}
				i = after + int(l)
			}
			5 {
				i += 4
			}
			else {
				return 0, 0, false
			}
		}
		if i > end {
			return 0, 0, false
		}
	}
	return a, b, true
}

// serve_grpc_sum answers GetSum: HEADERS, the SumReply frame as DATA without
// END_STREAM, then `grpc-status: 0` as trailers (they wait behind the DATA if
// flow control parks it).
fn serve_grpc_sum(mut hc H2cConn, req http2.Http2Request, mut out []u8) {
	a, b, ok := decode_sum_request(req.body)
	if !ok {
		hc.conn.write_response_headers(mut out, req.stream_id, grpc_invalid, true)
		return
	}
	sum := i32(a + b)
	hc.body.clear()
	// 5-byte gRPC prefix: uncompressed flag + big-endian length, patched below
	for _ in 0 .. 5 {
		hc.body << u8(0)
	}
	if sum != 0 {
		// proto3 omits a zero; a negative int32 goes out as a 10-byte varint
		hc.body << 0x08
		mut v := u64(i64(sum))
		for v >= 0x80 {
			hc.body << u8(v) | 0x80
			v >>= 7
		}
		hc.body << u8(v)
	}
	msg_len := hc.body.len - 5
	hc.body[4] = u8(msg_len)
	hc.conn.write_response_headers(mut out, req.stream_id, grpc_head_block, false)
	hc.conn.write_response_body(mut out, req.stream_id, hc.body, false)
	hc.conn.write_response_trailers(mut out, req.stream_id, grpc_ok_trailers)
}

// ── routing ──────────────────────────────────────────────────────────────────

// serve_request routes ONE complete http2 request and appends its response.
fn serve_request(mut hc H2cConn, ro &SharedRO, req http2.Http2Request, mut out []u8) {
	mut method := ''
	mut target := ''
	for f in req.headers {
		match f.name {
			':method' { method = f.value }
			':path' { target = f.value }
			else {}
		}
	}
	if method.len == 0 || target.len == 0 {
		respond_status(mut hc, req.stream_id, 400, mut out)
		return
	}
	if target == grpc_path {
		if method != 'POST' {
			respond_status(mut hc, req.stream_id, 405, mut out)
			return
		}
		serve_grpc_sum(mut hc, req, mut out)
		return
	}
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }
	if route == baseline2_route {
		hc.body.clear()
		wi(mut hc.body, q_int(target, 'a') + q_int(target, 'b'))
		respond(mut hc, req.stream_id, ctype_text, hc.body, mut out)
		return
	}
	if route.starts_with(json_route_prefix) {
		count := clamp_count(parse_u_at(route, json_route_prefix.len), ro.dataset.len)
		mut m := q_int(target, 'm')
		if m == 0 {
			m = 1
		}
		hc.body.clear()
		write_json_body(ro, mut hc.body, count, m)
		respond(mut hc, req.stream_id, ctype_json, hc.body, mut out)
		return
	}
	respond_status(mut hc, req.stream_id, 404, mut out)
}

// ── connection handlers ──────────────────────────────────────────────────────

// handle is the HTTP/1.1-side entry. The only h1 request it accepts is the
// http2 connection preface (PRI *); it flips the connection into the http2
// machine and returns the server preface. Every other h1 request is refused
// (505) — the port is h2c-only.
fn handle(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	hr := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	if slice_eq(hr.buffer, hr.method, pri_method) && slice_eq(hr.buffer, hr.path, star_target) {
		// Takeover FIRST: only answer with the server preface if this worker
		// can actually flip the connection's mode.
		mut hc := &H2cConn{
			conn:  http2.new_server_conn()
			reqs:  []http2.Http2Request{cap: 128}
			block: []u8{cap: 64}
			body:  []u8{cap: 4096}
		}
		if !core.queue_takeover(h2c_conn, voidptr(hc)) {
			res << cannot_takeover
			return .close
		}
		hc.conn.write_server_preface(mut res)
		return .done
	}
	res << h1_not_supported
	return .close
}

// h2c_conn is the core.ConnHandler for a flipped connection: the ServerConn
// consumes frames (answering SETTINGS/PING/WINDOW_UPDATE itself) and surfaces
// complete requests, routed through serve_request. The routes are synchronous,
// so the connection never suspends. takeover_state is the H2cConn;
// worker_state is the shared read-only dataset.
fn h2c_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut hc := unsafe { &H2cConn(takeover_state) }
	ro := unsafe { &SharedRO(worker_state) }
	hc.reqs.clear()
	consumed, closing := hc.conn.consume(buf, mut out, mut hc.reqs)
	for i in 0 .. hc.reqs.len {
		serve_request(mut hc, ro, hc.reqs[i], mut out)
	}
	if closing {
		return consumed, core.Step.close
	}
	return consumed, core.Step.done
}

fn main() {
	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode[[]DatasetItem](dataset_raw) or { []DatasetItem{} }
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}
	ro := &SharedRO{
		dataset:  dataset
		prefixes: prefixes
	}
	// :8080 serves the same routes for unary-grpc, which the harness drives
	// there. Its own server (own socket and workers), run on a thread while the
	// :8082 one blocks main below.
	grpc_srv := server.new_server(server.ServerConfig{
		port:            8080
		io_multiplexing: server.IOBackend.epoll
		handler:         handle
		make_state:      fn [ro] () voidptr {
			return voidptr(ro)
		}
	})!
	spawn fn [grpc_srv] () {
		mut s := grpc_srv
		s.run()
	}()
	// h2c on :8082 (HttpArena's h2c port). The takeover seam is epoll-first
	// (vanilla#136): on other backends queue_takeover reports false and the
	// preface is answered 501 instead of a dead SETTINGS.
	mut srv := server.new_server(server.ServerConfig{
		port:            8082
		io_multiplexing: server.IOBackend.epoll
		handler:         handle
		make_state:      fn [ro] () voidptr {
			return voidptr(ro)
		}
	})!
	srv.run()
}
