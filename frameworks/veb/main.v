module main

import veb
import db.pg
import json
import os
import strings

struct Rating {
	score i64
	count i64
}

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

struct DbItem {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
}

struct App {
mut:
	pool     pg.ConnectionPool
	dataset  []DatasetItem
	prefixes []string // per item: `{…,"total":`
}

struct Context {
	veb.Context
}

@['/pipeline']
pub fn (mut app App) pipeline(mut ctx Context) veb.Result {
	return ctx.text('ok')
}

@['/baseline11']
pub fn (mut app App) baseline_get(mut ctx Context) veb.Result {
	sum := qint(ctx.query, 'a') + qint(ctx.query, 'b')
	return ctx.text(sum.str())
}

@['/baseline11'; post]
pub fn (mut app App) baseline_post(mut ctx Context) veb.Result {
	sum := qint(ctx.query, 'a') + qint(ctx.query, 'b') + ctx.req.data.trim_space().i64()
	return ctx.text(sum.str())
}

@['/upload'; post]
pub fn (mut app App) upload(mut ctx Context) veb.Result {
	return ctx.text(ctx.req.data.len.str())
}

@['/json/:count']
pub fn (mut app App) json_ep(mut ctx Context, count int) veb.Result {
	n := clamp_count(count, app.dataset.len)
	mut m := qint(ctx.query, 'm')
	if m == 0 {
		m = 1
	}
	return ctx.send_response_to_client('application/json', app.json_body(n, m))
}

@['/async-db']
pub fn (mut app App) async_db_ep(mut ctx Context) veb.Result {
	return ctx.send_response_to_client('application/json', app.async_db(qint(ctx.query, 'min'),
		qint(ctx.query, 'max'), qint(ctx.query, 'limit')))
}

// json_body manually serializes the first `count` dataset items (no reflection):
// only `total` (price*quantity*m) varies per request, the rest is a precomputed prefix.
fn (app &App) json_body(count int, m i64) string {
	mut sb := strings.new_builder(count * 224 + 32)
	sb.write_string('{"items":[')
	for i in 0 .. count {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string(app.prefixes[i])
		sb.write_decimal(app.dataset[i].price * app.dataset[i].quantity * m)
		sb.write_u8(`}`)
	}
	sb.write_string('],"count":')
	sb.write_decimal(i64(count))
	sb.write_u8(`}`)
	return sb.str()
}

fn (mut app App) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	mut conn := app.pool.acquire() or { return '{"items":[],"count":0}' }
	rows := conn.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		[min.str(), max.str(), lim.str()]) or {
		app.pool.release(conn)
		return '{"items":[],"count":0}'
	}
	app.pool.release(conn)
	mut items := []DbItem{cap: rows.len}
	for row in rows {
		items << DbItem{
			id:       nn(row.vals[0]).int()
			name:     nn(row.vals[1])
			category: nn(row.vals[2])
			price:    nn(row.vals[3]).int()
			quantity: nn(row.vals[4]).int()
			active:   nn(row.vals[5]) == 't'
			tags:     json.decode([]string, nn3(row.vals[6], '[]')) or { [] }
			rating:   Rating{
				score: nn(row.vals[7]).i64()
				count: nn(row.vals[8]).i64()
			}
		}
	}
	return json.encode(DbResp{ items: items, count: items.len })
}

struct DbResp {
	items []DbItem
	count int
}

@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

fn qint(q map[string]string, key string) i64 {
	return (q[key] or { '' }).i64()
}

fn clamp_count(n int, max int) int {
	if n < 0 {
		return 0
	}
	if n > max {
		return max
	}
	return n
}

fn parse_db_url(u string) pg.Config {
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
	return pg.Config{
		host:     host_port.all_before(':')
		port:     port
		user:     creds.all_before(':')
		password: creds.all_after(':')
		dbname:   rest.all_after('/')
	}
}

fn main() {
	url := os.getenv_opt('DATABASE_URL') or { 'postgres://bench:bench@localhost:5432/benchmark' }
	mut size := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int()
	if size < 1 {
		size = 64
	}
	if size > 200 {
		size = 200
	}
	mut pool := pg.new_connection_pool(parse_db_url(url), size)!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset := json.decode([]DatasetItem, os.read_file(dataset_path) or { '[]' }) or {
		[]DatasetItem{}
	}
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	mut app := &App{
		pool:     pool
		dataset:  dataset
		prefixes: prefixes
	}
	veb.run[App, Context](mut app, 8080)
}
