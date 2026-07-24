module main

// WebSocket echo on vanilla's conn-mode seam (enghitalo/vanilla#136): one epoll
// engine, two protocols on the same connection. The HTTP handler stays a pure
// function of the request; on `GET /ws` with a well-formed RFC 6455 upgrade it
// appends the `101 Switching Protocols`, hands the CONNECTION over via
// core.queue_takeover and returns .done — from that point every readable burst
// is fed to ws_echo_conn (a core.ConnHandler) instead of the HTTP/1.1 state
// machine. Read buffering/compaction, batched flushes and EPOLLOUT
// backpressure are the engine's own, so a pipelined burst of frames
// (echo-ws-pipeline) is drained in one handler call and coalesced into one
// write. The websocket module is a pure RFC 6455 codec: framing/handshake
// bytes only, composed here.
//
// Byte discipline: const response prefixes, append_accept_key writes base64
// straight into the buffer, zero-copy views over the request — no `${}`/`+`
// anywhere on the serving path.
import vanilla.core
import vanilla.http1_1.request_parser
import vanilla.http1_1.response
import vanilla.server
import vanilla.websocket

const switching_prefix = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '.bytes()
const head_end = '\r\n\r\n'.bytes()

const home_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 47\r\nConnection: keep-alive\r\n\r\nWebSocket echo: connect a ws:// client to /ws\r\n'.bytes()
const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
// 501: this worker/backend cannot take connections over (queue_takeover
// returned false) — upgrading would leave the peer speaking unparsed frames.
const cannot_upgrade_response = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const bad_upgrade_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

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

const get_method = 'GET'.bytes()
const ws_path = '/ws'.bytes()
const root_path = '/'.bytes()
const upgrade_websocket = 'websocket'.bytes()

// handle is the HTTP side: routes, validates the upgrade, performs the
// takeover hand-off.
fn handle(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	hr := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	if !slice_eq(hr.buffer, hr.method, get_method) {
		res << not_found_response
		return .done
	}
	if slice_eq(hr.buffer, hr.path, root_path) {
		res << home_response
		return .done
	}
	if !slice_eq(hr.buffer, hr.path, ws_path) {
		res << not_found_response
		return .done
	}
	// GET /ws — validate the RFC 6455 §4.2.1 client handshake: an Upgrade:
	// websocket token and a Sec-WebSocket-Key to sign.
	upgrade := hr.get_header_value_slice('Upgrade') or {
		res << bad_upgrade_response
		return .close
	}
	if !slice_eq(hr.buffer, upgrade, upgrade_websocket) {
		res << bad_upgrade_response
		return .close
	}
	key := hr.get_header_value_slice('Sec-WebSocket-Key') or {
		res << bad_upgrade_response
		return .close
	}
	// The takeover FIRST: only append the 101 if this worker can actually flip
	// the connection's mode (queue_takeover is false on non-epoll backends —
	// the peer must then get a clear error, not a dead 101).
	if !core.queue_takeover(ws_echo_conn, unsafe { nil }) {
		res << cannot_upgrade_response
		return .close
	}
	res << switching_prefix
	websocket.append_accept_key(mut res, unsafe { tos(&hr.buffer[key.start], key.len) })
	res << head_end
	return .done
}

// ws_echo_conn drives the connection after the upgrade: a core.ConnHandler fed
// every readable burst. Echoes text/binary frames, answers pings with pongs,
// completes the close handshake.
fn ws_echo_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut consumed := 0
	for consumed < buf.len {
		mut rest := unsafe { (&buf[consumed]).vbytes(buf.len - consumed) }
		h := websocket.frame_head(rest)
		if h.total == websocket.incomplete {
			break // partial frame — the engine buffers the tail and re-calls
		}
		if h.total == websocket.err_malformed || !h.masked {
			// Framing violation, or an unmasked client frame (RFC 6455 §5.1
			// requires the server to fail the connection).
			websocket.write_close(mut out, websocket.close_protocol_error)
			return consumed, core.Step.close
		}
		websocket.unmask_in_place(mut rest, h)
		payload := if h.payload_len > 0 {
			unsafe { (&rest[h.payload_off]).vbytes(h.payload_len) }
		} else {
			[]u8{}
		}
		match h.opcode {
			websocket.op_text, websocket.op_binary {
				if !h.fin {
					// Whole messages only; the echo profile never fragments.
					websocket.write_close(mut out, websocket.close_unsupported)
					return consumed, core.Step.close
				}
				websocket.write_frame_header(mut out, h.opcode, h.payload_len)
				out << payload
			}
			websocket.op_ping {
				websocket.write_pong(mut out, payload)
			}
			websocket.op_pong {
				// unsolicited pong — ignored (RFC 6455 §5.5.3 allows it)
			}
			websocket.op_close {
				websocket.write_close(mut out, websocket.close_normal)
				return consumed + h.total, core.Step.close
			}
			else {
				// op_cont with no message in flight (the fin=false path above
				// already closed) — protocol error.
				websocket.write_close(mut out, websocket.close_protocol_error)
				return consumed, core.Step.close
			}
		}

		consumed += h.total
	}
	return consumed, core.Step.done
}

fn main() {
	// The takeover seam is epoll-first (vanilla#136): elsewhere queue_takeover
	// reports false and /ws answers 501 instead of a dead upgrade.
	mut srv := server.new_server(server.ServerConfig{
		port:            8080
		io_multiplexing: server.IOBackend.epoll
		handler:         handle
	})!
	srv.run()
}
