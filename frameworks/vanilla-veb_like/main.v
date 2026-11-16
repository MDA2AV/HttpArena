module main

// vanilla-veb_like: vanilla with its declarative router, http1_1.veb_like.
//
// Routes are attributes on the methods of App (the :8080 listener) and TlsApp
// (the :8081 TLS listener). veb_like.new compiles them into a segment trie at
// startup and fails on a malformed or conflicting route; per request it walks
// the trie, fills the route's :params and calls the method, and answers 404,
// 405 (with Allow) and 501 itself. What each route does is in app.v, shared
// with vanilla-router.
import vanilla.server
import vanilla.core
import vanilla.http1_1.request_parser { HttpRequest }
import vanilla.http1_1.veb_like { Params }
import os

// App holds no state: handlers reach the shared data and their worker's
// buffers and Postgres pool through `worker_state`.
struct App {}

@['GET /pipeline']
fn (app &App) pipeline(req HttpRequest, _ &Params, mut out []u8) core.Step {
	return pipeline(req, mut out)
}

@['GET /baseline11']
@['POST /baseline11']
fn (app &App) baseline(req HttpRequest, _ &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return baseline(mut w, req, mut out)
}

@['GET /json/:count']
fn (app &App) json(req HttpRequest, p &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return json_items(mut w, req, p.get('count'), mut out)
}

@['GET /async-db']
fn (app &App) async_db(req HttpRequest, _ &Params, mut out []u8, _ int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return async_db(mut w, req, mut out, mut event_loop)
}

@['GET /fortunes']
fn (app &App) fortunes(req HttpRequest, _ &Params, mut out []u8, _ int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return fortunes(mut w, req, mut out, mut event_loop)
}

// HEAD is routed here too, rather than to the GET route with its body cut:
// the asset server answers HEAD itself, and a large body may leave by
// sendfile(2), outside `out`.
@['GET /static/*path']
@['HEAD /static/*path']
fn (app &App) static_file(req HttpRequest, _ &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	w := unsafe { &Worker(worker_state) }
	return static_file(w, req, mut out)
}

@['POST /echo']
fn (app &App) echo(req HttpRequest, _ &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return echo(mut w, req, mut out)
}

@['GET /delay/:ms']
fn (app &App) delay(req HttpRequest, p &Params, mut out []u8, _ int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return delay(mut w, req, p.get('ms'), mut out, mut event_loop)
}

// TlsApp is the :8081 listener: /json (json-tls), /echo (8gbit) and /static
// (static-tls). The TLS worker has no event loop to park on, so its routes
// all answer synchronously.
struct TlsApp {}

@['GET /json/:count']
fn (app &TlsApp) json(req HttpRequest, p &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return json_items(mut w, req, p.get('count'), mut out)
}

@['POST /echo']
fn (app &TlsApp) echo(req HttpRequest, _ &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return echo(mut w, req, mut out)
}

@['GET /static/*path']
@['HEAD /static/*path']
fn (app &TlsApp) static_file(req HttpRequest, _ &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	w := unsafe { &Worker(worker_state) }
	return static_file(w, req, mut out)
}

fn main() {
	data := load_shared()
	db := parse_db_url(os.getenv_opt('DATABASE_URL') or {
		'postgres://bench:bench@localhost:5432/benchmark'
	})
	per_worker := pool_size()
	app_router := veb_like.new(&App{})!
	tls_router := veb_like.new(&TlsApp{})!

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
		handler:         fn [tls_router] (req []u8, mut out []u8, fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return tls_router.handle(req, mut out, fd, worker_state, mut event_loop)
		}
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
		handler:         fn [app_router] (req []u8, mut out []u8, fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return app_router.handle(req, mut out, fd, worker_state, mut event_loop)
		}
		make_state:      fn [data, db, per_worker] () voidptr {
			return new_worker(data, connect_pool(db, per_worker))
		}
	})!
	srv.run()
}
