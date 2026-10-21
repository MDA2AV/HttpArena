module main

import json
import os
import viltrum

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

fn main() {
	dataset := json.decode([]Item, os.read_file('/data/dataset.json') or { '[]' }) or { []Item{} }
	mut app := viltrum.new()
	// One copy of the dataset per worker: totals are written per request, and a
	// worker only touches its own copy.
	mut copies := [][]Item{}
	for _ in 0 .. app.worker_count() {
		copies << dataset.clone()
	}
	app.get('/baseline11', baseline)
	app.post('/baseline11', baseline)
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
	mut listeners := [viltrum.Listener{
		addr: '0.0.0.0:8080'
	}]
	// json-tls and 8gbit on 8081; the TLS hardening check on 9000 with its own pair,
	// which it replaces on disk while the server runs.
	for dir, port in {
		'/certs':     8081
		'/certs-tls': 9000
	} {
		if os.exists('${dir}/server.crt') {
			listeners << viltrum.Listener{
				addr: '0.0.0.0:${port}'
				tls:  viltrum.TlsOptions{
					cert_file: '${dir}/server.crt'
					key_file:  '${dir}/server.key'
				}
			}
		}
	}
	app.serve(listeners) or { panic(err) }
}

// first is a view of a's first n items; safe because n <= a.len and jsonenc only reads.
fn first(a []Item, n int) []Item {
	mut v := unsafe { a }
	unsafe {
		v.len = n
	}
	return v
}

fn delay_done(mut c viltrum.Ctx, ms u64) {
	c.text_int(200, i64(ms))
}

fn baseline(mut c viltrum.Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}
