module main

import json
import os
import runtime
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
}

struct PricedItem {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
	total    i64
}

struct JsonPage {
	items []PricedItem
	count int
}

fn main() {
	raw := os.read_file('/data/dataset.json') or { '[]' }
	dataset := json.decode([]Item, raw) or { []Item{} }

	mut app := viltrum.new()
	app.server_options(viltrum.ServerOptions{
		handle_signals: false
		send_date:      true
		server_header:  'viltrum'
		epoll_cores:    runtime.nr_cpus()
	})

	app.get('/baseline11', baseline)
	app.post('/baseline11', baseline)
	app.get('/pipeline', fn (_ viltrum.Request) viltrum.Response {
		return viltrum.text(200, 'ok')
	})
	app.get('/json/:count', viltrum.chain([viltrum.gzip], fn [dataset] (req viltrum.Request) viltrum.Response {
		mut n := (req.param('count') or { '0' }).int()
		if n < 0 {
			n = 0
		} else if n > dataset.len {
			n = dataset.len
		}
		m := i64((req.query_param('m') or { '1' }).int())
		mut items := []PricedItem{cap: n}
		for it in dataset[..n] {
			items << PricedItem{
				id:       it.id
				name:     it.name
				category: it.category
				price:    it.price
				quantity: it.quantity
				active:   it.active
				tags:     it.tags
				rating:   it.rating
				total:    i64(it.price) * i64(it.quantity) * m
			}
		}
		return viltrum.json(200, json.encode(JsonPage{ items: items, count: n }))
	}))
	app.ws('/ws', fn (mut s viltrum.WsSocket) {
		for {
			msg := s.read_message() or { break }
			if msg.is_text() {
				s.write_text(msg.text()) or { break }
			} else if msg.is_binary() {
				s.write_binary(msg.data) or { break }
			}
		}
		s.close_quiet()
	})
	app.listen('0.0.0.0:8080') or { panic(err) }
}

fn baseline(req viltrum.Request) viltrum.Response {
	mut sum := i64((req.query_param('a') or { '0' }).int()) +
		(req.query_param('b') or { '0' }).int()
	if req.body.len > 0 {
		sum += req.text().trim_space().i64()
	}
	return viltrum.text(200, sum.str())
}
