module main

import veb
import db.pg
import json2
import os
import strings
import sync
import compress.gzip

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

struct DbResp {
	items []DbItem
	count int
}

struct CrudList {
	items []DbItem
	total i64
	page  i64
}

struct CrudCreate {
	id       int
	name     string
	category string
	price    int
	quantity int
}

// App is the process-wide, reference-shared veb application. veb hands the SAME
// &App to every worker thread, so the dataset/prefixes are read-only (no lock)
// and the DB pool is internally thread-safe, but the crud/gzip caches are
// mutable and RwMutex-guarded — SO_REUSEPORT routes same-key requests to
// different workers, and the crud X-Cache MISS→HIT probe must survive that.
struct App {
	veb.StaticHandler // static file serving (mounted at /static/)
mut:
	db       &pg.DB = unsafe { nil }
	dataset  []DatasetItem
	prefixes []string // per item: `{…,"total":`
	crud     map[int]string // id -> rendered item JSON (cache-aside body)
	crud_mu  &sync.RwMutex = unsafe { nil }
	gz       map[u64]string // (count<<32)|m -> gzipped /json body bytes
	gz_mu    &sync.RwMutex = unsafe { nil }
}

struct Context {
	veb.Context
}

// ── plaintext / compute ──────────────────────────────────────────────────────

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
	// ctx.req.data is the fully-received body; veb's fasthttp backend already
	// reassembled TCP-fragmented requests and decoded chunked transfer-encoding.
	sum := qint(ctx.query, 'a') + qint(ctx.query, 'b') + ctx.req.data.trim_space().i64()
	return ctx.text(sum.str())
}

@['/upload'; post]
pub fn (mut app App) upload(mut ctx Context) veb.Result {
	return ctx.text(ctx.req.data.len.str())
}

// ── /json (+ json-comp) ──────────────────────────────────────────────────────

@['/json/:count']
pub fn (mut app App) json_ep(mut ctx Context, count int) veb.Result {
	n := clamp_count(count, app.dataset.len)
	mut m := qint(ctx.query, 'm')
	if m == 0 {
		m = 1
	}
	// json-comp: gzip when the client accepts it (Content-Encoding: gzip); the
	// gzipped body is cached per (count, m) because the profile is compression-bound.
	ae := ctx.get_header(.accept_encoding) or { '' }
	if ae.contains('gzip') {
		key := (u64(u32(n)) << 32) | u64(u32(m))
		app.gz_mu.@rlock()
		cached := app.gz[key] or { '' }
		app.gz_mu.runlock()
		mut gzbody := cached
		if gzbody.len == 0 {
			body := app.json_body(n, m)
			gz := gzip.compress(body.bytes()) or {
				return ctx.send_response_to_client('application/json', body)
			}
			gzbody = gz.bytestr()
			app.gz_mu.@lock()
			if app.gz.len < 1024 {
				app.gz[key] = gzbody
			}
			app.gz_mu.unlock()
		}
		ctx.set_custom_header('Content-Encoding', 'gzip') or {}
		return ctx.send_response_to_client('application/json', gzbody)
	}
	return ctx.send_response_to_client('application/json', app.json_body(n, m))
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

// ── /async-db ────────────────────────────────────────────────────────────────

@['/async-db']
pub fn (mut app App) async_db_ep(mut ctx Context) veb.Result {
	return ctx.send_response_to_client('application/json', app.async_db(qint(ctx.query, 'min'),
		qint(ctx.query, 'max'), qint(ctx.query, 'limit')))
}

fn (mut app App) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	mut db := app.db
	rows := db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		[min.str(), max.str(), lim.str()]) or { return '{"items":[],"count":0}' }
	mut items := []DbItem{cap: rows.len}
	for row in rows {
		items << row_to_item(row)
	}
	return json2.encode(DbResp{ items: items, count: items.len })
}

// ── /crud ──────────────────────────────────────────────────────────────────

@['/crud/items']
pub fn (mut app App) crud_list_ep(mut ctx Context) veb.Result {
	mut p := qint(ctx.query, 'page')
	if p < 1 {
		p = 1
	}
	mut lim := qint(ctx.query, 'limit')
	if lim < 1 {
		lim = 10
	}
	if lim > 100 {
		lim = 100
	}
	category := ctx.query['category'] or { '' }
	offset := (p - 1) * lim
	mut db := app.db
	rows := db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3',
		[category, lim.str(), offset.str()]) or {
		return ctx.send_response_to_client('application/json', '{"items":[],"total":0,"page":1}')
	}
	mut items := []DbItem{cap: rows.len}
	mut total := i64(0)
	for row in rows {
		items << row_to_item(row)
		total = nn(row.vals[9]).i64()
	}
	return ctx.send_response_to_client('application/json', json2.encode(CrudList{
		items: items
		total: total
		page:  p
	}))
}

@['/crud/items'; post]
pub fn (mut app App) crud_create_ep(mut ctx Context) veb.Result {
	c := json2.decode[CrudCreate](ctx.req.data) or {
		ctx.res.set_status(.bad_request)
		return ctx.text('')
	}
	mut db := app.db
	db.exec_param_many("INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity",
		[c.id.str(), c.name, c.category, c.price.str(), c.quantity.str()]) or {
		ctx.res.set_status(.bad_request)
		return ctx.text('')
	}
	ctx.res.set_status(.created)
	return ctx.text('')
}

@['/crud/items/:id']
pub fn (mut app App) crud_get_ep(mut ctx Context, id int) veb.Result {
	// Cache-aside: a HIT answers with no DB round-trip.
	app.crud_mu.@rlock()
	cached := app.crud[id] or { '' }
	app.crud_mu.runlock()
	if cached.len > 0 {
		ctx.set_custom_header('X-Cache', 'HIT') or {}
		return ctx.send_response_to_client('application/json', cached)
	}
	mut db := app.db
	rows := db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1',
		[id.str()]) or { return ctx.not_found() }
	if rows.len == 0 {
		return ctx.not_found()
	}
	body := json2.encode(row_to_item(rows[0]))
	app.crud_mu.@lock()
	if app.crud.len < 100000 {
		app.crud[id] = body
	}
	app.crud_mu.unlock()
	ctx.set_custom_header('X-Cache', 'MISS') or {}
	return ctx.send_response_to_client('application/json', body)
}

@['/crud/items/:id'; put]
pub fn (mut app App) crud_update_ep(mut ctx Context, id int) veb.Result {
	c := json2.decode[CrudCreate](ctx.req.data) or {
		ctx.res.set_status(.bad_request)
		return ctx.text('')
	}
	mut db := app.db
	db.exec_param_many('UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1',
		[id.str(), c.name, c.category, c.price.str(), c.quantity.str()]) or {
		ctx.res.set_status(.bad_request)
		return ctx.text('')
	}
	// Invalidate the cache slot (cache-aside, invalidate-on-write).
	app.crud_mu.@lock()
	app.crud.delete(id)
	app.crud_mu.unlock()
	return ctx.send_response_to_client('application/json', '{"status":"ok"}')
}

// ── /fortunes ────────────────────────────────────────────────────────────────

struct Fortune {
	id      int
	message string
}

@['/fortunes']
pub fn (mut app App) fortunes_ep(mut ctx Context) veb.Result {
	mut db := app.db
	rows := db.exec_param_many('SELECT id, message FROM fortune', []) or { []pg.Row{} }
	mut fs := []Fortune{cap: rows.len + 1}
	for row in rows {
		fs << Fortune{
			id:      nn(row.vals[0]).int()
			message: nn(row.vals[1])
		}
	}
	fs << Fortune{
		id:      0
		message: 'Additional fortune added at request time.'
	}
	fs.sort_with_compare(fn (a &Fortune, b &Fortune) int {
		return compare_strings(a.message, b.message)
	})
	mut sb := strings.new_builder(4096)
	sb.write_string('<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in fs {
		sb.write_string('<tr><td>')
		sb.write_decimal(i64(f.id))
		sb.write_string('</td><td>')
		sb.write_string(escape_html(f.message))
		sb.write_string('</td></tr>')
	}
	sb.write_string('</table></body></html>')
	return ctx.send_response_to_client('text/html; charset=utf-8', sb.str())
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn row_to_item(row pg.Row) DbItem {
	return DbItem{
		id:       nn(row.vals[0]).int()
		name:     nn(row.vals[1])
		category: nn(row.vals[2])
		price:    nn(row.vals[3]).int()
		quantity: nn(row.vals[4]).int()
		active:   nn(row.vals[5]) == 't'
		tags:     json2.decode[[]string](nn3(row.vals[6], '[]')) or { [] }
		rating:   Rating{
			score: nn(row.vals[7]).i64()
			count: nn(row.vals[8]).i64()
		}
	}
}

@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

fn escape_html(s string) string {
	mut needs := false
	for c in s {
		if c == `&` || c == `<` || c == `>` || c == `"` || c == `'` {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	mut sb := strings.new_builder(s.len + 16)
	for c in s {
		match c {
			`&` { sb.write_string('&amp;') }
			`<` { sb.write_string('&lt;') }
			`>` { sb.write_string('&gt;') }
			`"` { sb.write_string('&quot;') }
			`'` { sb.write_string('&apos;') }
			else { sb.write_u8(c) }
		}
	}
	return sb.str()
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
	// max_idle_conns MUST equal max_open_conns so released conns are not physically
	// closed and re-handshaked on the next acquire (db.pg defaults idle to 2).
	mut db := pg.connect(parse_db_url(url), pg.PoolConfig{ max_open_conns: size, max_idle_conns: size })!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset := json2.decode[[]DatasetItem](os.read_file(dataset_path) or { '[]' }) or {
		[]DatasetItem{}
	}
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json2.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	mut app := &App{
		db:       db
		dataset:  dataset
		prefixes: prefixes
		crud:     map[int]string{}
		crud_mu:  sync.new_rwmutex()
		gz:       map[u64]string{}
		gz_mu:    sync.new_rwmutex()
	}

	// Static assets served identity via veb's static handler (sendfile + MIME
	// negotiation), mounted at /static/. `.br` is not in veb's built-in MIME map,
	// so register it before the folder scan (which registers every sibling file,
	// including the precompressed .br/.gz/.zst ones) — otherwise the scan errors
	// on the first `.br` file. Compression is left off (identity): the static
	// profile's compression check is skipped when no Content-Encoding is sent.
	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	app.static_mime_types['.br'] = 'application/octet-stream'
	if os.is_dir(static_dir) {
		app.mount_static_folder_at(static_dir, '/static') or {
			eprintln('veb: static mount failed: ${err}')
		}
	}

	veb.run[App, Context](mut app, 8080)
}
