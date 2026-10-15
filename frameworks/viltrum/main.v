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
	app.get('/json/:count', viltrum.gzip, fn [mut copies] (mut c viltrum.Ctx) {
		mut items := copies[c.worker_id()]
		mut n := int(c.param_int('count') or { 0 })
		if n < 0 {
			n = 0
		} else if n > items.len {
			n = items.len
		}
		m := c.query_int('m') or { 1 }
		for i in 0 .. n {
			items[i].total = i64(items[i].price) * i64(items[i].quantity) * m
		}
		mut page := unsafe { items }
		unsafe {
			// n is clamped to items.len and jsonenc only reads page, so the shortened view is safe
			page.len = n
		}
		c.json(200, Page{
			items: page
			count: n
		})
	})
	app.listen('0.0.0.0:8080') or { panic(err) }
}

fn baseline(mut c viltrum.Ctx) {
	sum := (c.query_int('a') or { 0 }) + (c.query_int('b') or { 0 }) + (c.body_int() or { 0 })
	c.text_int(200, sum)
}
