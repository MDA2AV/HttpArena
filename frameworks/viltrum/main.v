module main

import encoding.html
import net
import os
import viltrum
import x.json2

struct Rating {
	score int
	count int
}

struct Item {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
mut:
	total i64
}

struct Page {
	items []Item
	count int
}

struct TlsPort {
	dir   string
	port  int
	http2 bool
}

fn main() {
	dataset := json2.decode[[]Item](os.read_file('/data/dataset.json') or { '[]' }) or { []Item{} }
	mut app := viltrum.new()
	// async-db: one connection per thread, up to DATABASE_MAX_CONN less the few
	// Postgres keeps for the superuser
	mut conns := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int() - 4
	if conns < 1 {
		conns = 1
	}
	mut pg := new_pg(app, os.getenv('DATABASE_URL'), conns)
	pg_done := fn [mut pg] (mut c viltrum.Ctx, token u64) {
		pg.answer(mut c, token)
	}
	// One copy of the dataset per worker: totals are written per request, and a
	// worker only touches its own copy.
	mut copies := [][]Item{}
	for _ in 0 .. app.worker_count() {
		copies << dataset.clone()
	}
	app.get('/baseline11', baseline)
	app.post('/baseline11', baseline)
	app.get('/async-db', fn [mut pg, pg_done] (mut c viltrum.Ctx) {
		token := pg.submit(q_items, db_i(mut c, 'min', 10), db_i(mut c, 'max', 50), db_limit(mut c))
		if token == 0 {
			c.bytes(200, 'application/json', db_empty)
			return
		}
		c.suspend(token, 30000, pg_done, token)
	})
	// fortunes: the same pool and parking as async-db; the page is rendered on the
	// worker when the rows are in (fortunes_answer)
	app.get('/fortunes', fn [mut pg, pg_done] (mut c viltrum.Ctx) {
		token := pg.submit(q_fortunes, 0, 0, 0)
		if token == 0 {
			c.text(503, 'database unavailable')
			return
		}
		c.suspend(token, 30000, pg_done, token)
	})
	// the HTTP/2 profiles' baseline, on 8082 (h2c) and 8443 (h2)
	app.get('/baseline2', baseline)
	// static-h2: the files from disk, their .br and .gz copies to clients that accept them
	app.static_files('/static', '/data/static', precompressed: true)
	app.get('/pipeline', fn (mut c viltrum.Ctx) {
		c.text(200, 'ok')
	})
	// Only scalars are local here: V -prod pins every local struct or array around each
	// call statement (see docs/request-response.md), so the dataset stays captured.
	app.get('/json/:count', viltrum.gzip, fn [mut copies] (mut c viltrum.Ctx) {
		w := c.worker_id()
		mut n := int(c.param_int('count') or { 0 })
		if n < 0 {
			n = 0
		} else if n > copies[w].len {
			n = copies[w].len
		}
		m := c.query_int('m') or { 1 }
		for i in 0 .. n {
			copies[w][i].total = i64(copies[w][i].price) * i64(copies[w][i].quantity) * m
		}
		c.json(200, Page{
			items: first(copies[w], n)
			count: n
		})
	})
	// The worker is not held while a request waits: after() answers it from a timer.
	app.get('/delay/:ms', fn (mut c viltrum.Ctx) {
		ms := c.param_int('ms') or { -1 }
		if ms < 0 {
			c.text(400, 'bad delay')
			return
		}
		c.after(int(ms), delay_done, u64(ms))
	})
	// 8gbit: the body comes back through the framework's body and response API.
	app.post('/echo', fn (mut c viltrum.Ctx) {
		c.bytes(200, 'application/octet-stream', c.body())
	})
	// /spec: the route the compliance suites (Http11Probe, h2spec) run against. HEAD
	// falls back to GET and the engine drops the body.
	app.get('/spec', fn (mut c viltrum.Ctx) {
		c.text(200, 'spec ok')
	})
	app.post('/spec', fn (mut c viltrum.Ctx) {
		c.bytes(200, 'application/octet-stream', c.body())
	})
	app.options('/spec', fn (mut c viltrum.Ctx) {
		_ = c.body()
		c.set_header('Allow', 'GET, HEAD, POST, OPTIONS')
		c.text(200, '')
	})
	app.get('/spec/headers', spec_headers)
	app.post('/spec/headers', spec_headers)
	// echo-ws: each message comes back as it came, text or binary, from the worker
	// that owns the connection.
	app.ws('/ws', viltrum.WsHandler{
		on_message: fn (mut s viltrum.Ws, m viltrum.WsMessage) {
			if m.binary {
				s.send_binary(m.data)
			} else {
				s.send_text(m.text())
			}
		}
	})
	mut listeners := []viltrum.Listener{}
	// gateway-64's server: plain HTTP on PROXY_PORT, and 8080 when it is free so the
	// benchmark's readiness probe has something to ask. No TLS here; the proxy holds 8443.
	if port := os.getenv_opt('PROXY_PORT') {
		listeners << viltrum.Listener{
			addr: '0.0.0.0:${port}'
		}
		if probe := os.getenv_opt('H1_PROBE_PORT') {
			if probe != port && can_listen('0.0.0.0:${probe}') {
				listeners << viltrum.Listener{
					addr: '0.0.0.0:${probe}'
				}
			}
		}
	} else {
		listeners << viltrum.Listener{
			addr: '0.0.0.0:8080'
		}
		// baseline-h2c and json-h2c: HTTP/2 with prior knowledge (and HTTP/1.1) on 8082
		listeners << viltrum.Listener{
			addr:  '0.0.0.0:8082'
			http2: true
		}
	}
	// json-tls, static-tls and 8gbit on 8081 (HTTP/1.1 only); baseline-h2 and static-h2
	// on 8443, HTTP/2 chosen by ALPN; the TLS hardening check on 9000 with its own pair,
	// which it replaces on disk while the server runs. The gateway server skips these:
	// the proxy owns 8443, and binding it here would share the port.
	if os.getenv_opt('PROXY_PORT') == none {
		for l in [TlsPort{'/certs', 8081, false}, TlsPort{'/certs', 8443, true},
			TlsPort{'/certs-tls', 9000, false}] {
			if os.exists('${l.dir}/server.crt') {
				listeners << viltrum.Listener{
					addr:  '0.0.0.0:${l.port}'
					http2: l.http2
					tls:   viltrum.TlsOptions{
						cert_file: '${l.dir}/server.crt'
						key_file:  '${l.dir}/server.key'
					}
				}
			}
		}
	}
	app.serve(listeners) or { panic(err) }
}

fn can_listen(addr string) bool {
	mut l := net.listen_tcp(.ip, addr) or { return false }
	l.close() or {}
	return true
}

fn db_i(mut c viltrum.Ctx, name string, def int) int {
	n := c.query_int(name) or { return def }
	if n > 2147483647 {
		return 2147483647
	}
	if n < -2147483647 {
		return -2147483647
	}
	return int(n)
}

fn db_limit(mut c viltrum.Ctx) int {
	n := int(c.query_int('limit') or { 50 })
	if n < 1 {
		return 1
	}
	if n > 50 {
		return 50
	}
	return n
}

// first is a view of a's first n items; safe because n <= a.len and jsonenc only reads.
fn first(a []Item, n int) []Item {
	mut v := unsafe { a }
	unsafe {
		v.len = n
	}
	return v
}

// fortunes_answer adds the request-time row, sorts by message in byte order and
// renders fortunes.html. rows are the slot's, owned by this request until release.
fn fortunes_answer(mut c viltrum.Ctx, mut rows []Fortune) {
	if rows.len == 0 {
		c.text(503, 'database unavailable')
		return
	}
	rows << Fortune{0, 'Additional fortune added at request time.'}
	rows.sort(a.message < b.message)
	c.html(200, fortunes_page(rows))
}

// fortunes_page runs the compile-time template. V's $tmpl does not escape on its own
// (only $veb.html does, and that writes to a veb.Context), so the template escapes
// the message itself with esc.
fn fortunes_page(rows []Fortune) string {
	return $tmpl('fortunes.html')
}

// esc is encoding.html's escape, named here because a template sees the function's
// scope, not the file's imports.
fn esc(s string) string {
	return html.escape(s)
}

fn delay_done(mut c viltrum.Ctx, ms u64) {
	c.text_int(200, i64(ms))
}

// spec_headers lists the request's fields as the parser stored them, one `Name: Value` a line.
fn spec_headers(mut c viltrum.Ctx) {
	_ = c.body()
	mut out := []u8{cap: 1024}
	for k in 0 .. c.head.nfields {
		f := c.head.fields[k]
		out << c.buf[f.name.start..f.name.start + f.name.len]
		out << ': '.bytes()
		out << c.buf[f.value.start..f.value.start + f.value.len]
		out << `\n`
	}
	c.bytes(200, 'text/plain', out)
}

fn baseline(mut c viltrum.Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}
