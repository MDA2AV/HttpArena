module main

// vanilla-router: vanilla with its explicit router, http1_1.router.
//
// The routes are `match` statements over the request's path segments, read
// with router.method and router.path: a zero-copy cursor over the request
// line. What each route does is in app.v, shared with vanilla-veb_like.
import vanilla.server
import vanilla.core
import vanilla.http1_1.request_parser { HttpRequest }
import vanilla.http1_1.router
import os

// bad_request_response answers a request the parser rejects, and closes.
const bad_request_response = 'HTTP/1.1 400 Bad Request\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

// handle routes the :8080 listener.
fn handle(req_buffer []u8, mut out []u8, _ int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	mut req := HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		core.append_str(mut out, bad_request_response)
		return .close
	}
	m := router.method(req_buffer)
	mut path := router.path(req_buffer)
	match path.next() {
		'pipeline' {
			if path.done() {
				return if m == .get {
					pipeline(req, mut out)
				} else {
					not_allowed(mut out, req, 'GET')
				}
			}
		}
		'baseline11' {
			if path.done() {
				return if m == .get || m == .post {
					baseline(mut w, req, mut out)
				} else {
					not_allowed(mut out, req, 'GET, POST')
				}
			}
		}
		'json' {
			count := path.next()
			if path.done() && count != '' {
				return if m == .get {
					json_items(mut w, req, count, mut out)
				} else {
					not_allowed(mut out, req, 'GET')
				}
			}
		}
		'async-db' {
			if path.done() {
				return if m == .get {
					async_db(mut w, req, mut out, mut event_loop)
				} else {
					not_allowed(mut out, req, 'GET')
				}
			}
		}
		'fortunes' {
			if path.done() {
				return if m == .get {
					fortunes(mut w, req, mut out, mut event_loop)
				} else {
					not_allowed(mut out, req, 'GET')
				}
			}
		}
		'static' {
			// the asset server answers GET and HEAD, and 405s anything else
			return static_file(w, req, mut out)
		}
		'echo' {
			if path.done() {
				return if m == .post {
					echo(mut w, req, mut out)
				} else {
					not_allowed(mut out, req, 'POST')
				}
			}
		}
		'delay' {
			ms := path.next()
			if path.done() && ms != '' {
				return if m == .get {
					delay(mut w, req, ms, mut out, mut event_loop)
				} else {
					not_allowed(mut out, req, 'GET')
				}
			}
		}
		else {}
	}
	core.append_str(mut out, not_found_response)
	return step_for(req)
}

// handle_tls routes the :8081 TLS listener: /json (json-tls), /echo (8gbit)
// and /static (static-tls). The TLS worker has no event loop to park on, so
// these routes all answer synchronously.
fn handle_tls(req_buffer []u8, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	mut req := HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		core.append_str(mut out, bad_request_response)
		return .close
	}
	m := router.method(req_buffer)
	mut path := router.path(req_buffer)
	match path.next() {
		'json' {
			count := path.next()
			if path.done() && count != '' {
				return if m == .get {
					json_items(mut w, req, count, mut out)
				} else {
					not_allowed(mut out, req, 'GET')
				}
			}
		}
		'echo' {
			if path.done() {
				return if m == .post {
					echo(mut w, req, mut out)
				} else {
					not_allowed(mut out, req, 'POST')
				}
			}
		}
		'static' {
			return static_file(w, req, mut out)
		}
		else {}
	}
	core.append_str(mut out, not_found_response)
	return step_for(req)
}

// not_allowed answers 405 for a path that exists under other methods.
fn not_allowed(mut out []u8, req HttpRequest, allow string) core.Step {
	core.append_str(mut out, 'HTTP/1.1 405 Method Not Allowed\r\nServer: vanilla\r\nAllow: ')
	core.append_str(mut out, allow)
	core.append_str(mut out, '\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n')
	return step_for(req)
}

fn main() {
	data := load_shared()
	db := parse_db_url(os.getenv_opt('DATABASE_URL') or {
		'postgres://bench:bench@localhost:5432/benchmark'
	})
	per_worker := pool_size()

	// :8081, HTTP/1.1 over TLS 1.3 (Mbed TLS, ALPN http/1.1). It is its own
	// server because the TLS configuration is server-wide; it runs on its own
	// thread while the plaintext server below blocks main.
	tls_server := server.new_server(server.ServerConfig{
		port:            tls_port()
		io_multiplexing: .epoll
		limits:          server.Limits{
			// 8gbit posts 10 KB; validation posts up to 100 KB, chunked included
			max_request_bytes: 256 * 1024
		}
		handler:         handle_tls
		make_state:      fn [data] () voidptr {
			return new_worker(data, unsafe { nil })
		}
		tls_config:      tls_config()
	})!
	spawn fn [tls_server] () {
		mut s := tls_server
		s.run()
	}()

	mut srv := server.new_server(server.ServerConfig{
		port:            8080
		io_multiplexing: .epoll
		limits:          server.Limits{
			max_request_bytes: 32 * 1024 * 1024
		}
		handler:         handle
		make_state:      fn [data, db, per_worker] () voidptr {
			return new_worker(data, connect_pool(db, per_worker))
		}
	})!
	srv.run()
}
