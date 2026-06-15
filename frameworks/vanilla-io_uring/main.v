module main

import vanilla.http_server
import vanilla.http_server.http1_1.request_parser
import db.pg
import json
import os
import strings
import sync
import compress.gzip

struct Rating {
	score i64
	count i64
}

// Dataset item as stored in /data/dataset.json.
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

struct Fortune {
	id      int
	message string
}

// A static asset preloaded into memory with its full HTTP response.
struct StaticFile {
	response []u8
}

struct Shared {
mut:
	pool     pg.ConnectionPool
	dataset  []DatasetItem
	prefixes []string // per item: `{…,"total":` (everything but the request-dependent total)
	assets   map[string]StaticFile // /static/<name> -> prebuilt response
	cache    map[int]string        // crud cache-aside: id -> item JSON
	cache_mu &sync.RwMutex = unsafe { nil }
}

struct CrudCreate {
	id       int
	name     string
	category string
	price    int
	quantity int
}

// ws appends a string's bytes to `out` with no allocation (push_many copies
// straight from the string's backing storage into the connection write buffer).
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wi appends the decimal digits of a non-negative integer to `out`, no
// allocation (itoa into a stack scratch, emitted most-significant-first).
@[direct_array_access]
fn wi(mut out []u8, n i64) {
	if n == 0 {
		out << u8(`0`)
		return
	}
	mut x := n
	mut tmp := [20]u8{}
	mut i := 0
	for x > 0 {
		tmp[i] = u8(`0`) + u8(x % 10)
		x /= 10
		i++
	}
	for i > 0 {
		i--
		out << tmp[i]
	}
}

// write_resp appends a complete HTTP/1.1 response (status line + headers + body)
// straight into the connection's persistent write buffer — no intermediate
// strings.Builder, no body→response copy, no per-request heap allocation. This
// is the zero-alloc twin of `ok()`; the latter survives only for the DB paths
// that are allocation-bound anyway.
fn write_resp(mut out []u8, ctype string, body string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

fn handle(req_buffer []u8, _fd int, mut out []u8, mut sh Shared) ! {
	req := request_parser.decode_http_request(req_buffer)!
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	route := target.all_before('?')

	if route == '/pipeline' {
		write_resp(mut out, 'text/plain', 'ok')
	} else if route == '/baseline11' {
		mut sum := qint(req, 'a') + qint(req, 'b')
		if method == 'POST' {
			sum += body_int(req)
		}
		write_resp(mut out, 'text/plain', sum.str())
	} else if route == '/upload' {
		write_resp(mut out, 'text/plain', req.body.len.str())
	} else if route.starts_with('/json/') {
		count := clamp_count(route[6..].i64(), sh.dataset.len)
		mut m := qint(req, 'm')
		if m == 0 {
			m = 1
		}
		if accepts_gzip(req) {
			// json-comp profile: gzip the body and set Content-Encoding.
			sh.write_json_gzip(mut out, count, m)
		} else {
			sh.write_json_response(mut out, count, m)
		}
	} else if route == '/async-db' {
		write_resp(mut out, 'application/json', sh.async_db(qint(req, 'min'), qint(req, 'max'),
			qint(req, 'limit')))
	} else if route == '/fortunes' {
		write_resp(mut out, 'text/html; charset=utf-8', sh.fortunes())
	} else if route.starts_with('/static/') {
		if f := sh.assets[route[8..]] {
			out << f.response
		} else {
			out << not_found
		}
	} else if route == '/crud/items' {
		if method == 'POST' {
			out << sh.crud_create(req)
		} else {
			out << sh.crud_list(qstr(req, 'category'), qint(req, 'page'), qint(req, 'limit'))
		}
	} else if route.starts_with('/crud/items/') {
		id := route[12..].int()
		if method == 'PUT' {
			out << sh.crud_update(id, req)
		} else {
			out << sh.crud_get(id)
		}
	} else {
		out << not_found
	}
}

// crud_list returns a paginated, category-filtered page of items.
fn (mut sh Shared) crud_list(category string, page i64, limit i64) []u8 {
	mut p := page
	if p < 1 {
		p = 1
	}
	mut lim := limit
	if lim < 1 {
		lim = 10
	}
	if lim > 100 {
		lim = 100
	}
	offset := (p - 1) * lim
	mut conn := sh.pool.acquire() or { return ok('application/json', '{"items":[],"total":0,"page":1}') }
	rows := conn.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3',
		[category, lim.str(), offset.str()]) or {
		sh.pool.release(conn)
		return ok('application/json', '{"items":[],"total":0,"page":1}')
	}
	trows := conn.exec_param_many('SELECT count(*) FROM items WHERE category = \$1', [category]) or {
		[]
	}
	sh.pool.release(conn)
	total := if trows.len > 0 { nn(trows[0].vals[0]).int() } else { 0 }
	mut items := []DbItem{cap: rows.len}
	for row in rows {
		items << row_to_item(row)
	}
	mut sb := strings.new_builder(items.len * 200 + 64)
	sb.write_string('{"items":')
	sb.write_string(json.encode(items))
	sb.write_string(',"total":')
	sb.write_decimal(i64(total))
	sb.write_string(',"page":')
	sb.write_decimal(p)
	sb.write_u8(`}`)
	return ok('application/json', sb.str())
}

// crud_get returns a single item, using a cache-aside in-memory cache and
// reporting the result via the X-Cache header (MISS on first read, HIT after).
fn (mut sh Shared) crud_get(id int) []u8 {
	sh.cache_mu.@rlock()
	cached := sh.cache[id] or { '' }
	sh.cache_mu.runlock()
	if cached.len > 0 {
		return ok_xcache('application/json', cached, 'HIT')
	}
	mut conn := sh.pool.acquire() or { return not_found }
	rows := conn.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1',
		[id.str()]) or {
		sh.pool.release(conn)
		return not_found
	}
	sh.pool.release(conn)
	if rows.len == 0 {
		return not_found
	}
	body := json.encode(row_to_item(rows[0]))
	sh.cache_mu.@lock()
	sh.cache[id] = body
	sh.cache_mu.unlock()
	return ok_xcache('application/json', body, 'MISS')
}

// crud_create inserts a new item from the JSON body and returns 201.
fn (mut sh Shared) crud_create(req request_parser.HttpRequest) []u8 {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or { return bad_request }
	mut conn := sh.pool.acquire() or { return bad_request }
	conn.exec_param_many("INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity",
		[c.id.str(), c.name, c.category, c.price.str(), c.quantity.str()]) or {
		sh.pool.release(conn)
		return bad_request
	}
	sh.pool.release(conn)
	return created
}

// crud_update updates an item and invalidates its cache entry.
fn (mut sh Shared) crud_update(id int, req request_parser.HttpRequest) []u8 {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or { return bad_request }
	mut conn := sh.pool.acquire() or { return bad_request }
	conn.exec_param_many('UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1',
		[id.str(), c.name, c.category, c.price.str(), c.quantity.str()]) or {
		sh.pool.release(conn)
		return bad_request
	}
	sh.pool.release(conn)
	sh.cache_mu.@lock()
	sh.cache.delete(id)
	sh.cache_mu.unlock()
	return ok('application/json', '{"status":"ok"}')
}

fn row_to_item(row pg.Row) DbItem {
	return DbItem{
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

const not_found = 'HTTP/1.1 404 Not Found\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const created = 'HTTP/1.1 201 Created\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const bad_request = 'HTTP/1.1 400 Bad Request\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// json_response builds the FULL HTTP response (headers + body) for /json in a
// single allocation — no per-request reflection and no body→response copy.
// Only `total` (price*quantity*m) varies per request; the rest is a precomputed
// prefix. Content-Length is computed up front so everything lands in one buffer.
fn (sh &Shared) write_json_response(mut out []u8, count int, m i64) {
	mut clen := 21 + digits(i64(count)) // len('{"items":[') + len('],"count":') + '}' + count digits
	if count > 0 {
		clen += count - 1 // item separators
	}
	for i in 0 .. count {
		t := sh.dataset[i].price * sh.dataset[i].quantity * m
		clen += sh.prefixes[i].len + digits(t) + 1 // prefix + total + '}'
	}
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(clen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		if i > 0 {
			out << `,`
		}
		ws(mut out, sh.prefixes[i])
		wi(mut out, sh.dataset[i].price * sh.dataset[i].quantity * m)
		out << `}`
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	out << `}`
}

// write_json_gzip is the json-comp path: build the body, gzip it, and append
// headers + compressed bytes into `out`. gzip needs a contiguous input, so this
// path still allocates the body — but json-comp is compression-bound, not
// allocation-bound, and the response no longer round-trips through a Builder.
fn (sh &Shared) write_json_gzip(mut out []u8, count int, m i64) {
	body := sh.json_body(count, m)
	gz := gzip.compress(body.bytes()) or {
		write_resp(mut out, 'application/json', body)
		return
	}
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(gz.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	unsafe { out.push_many(gz.data, gz.len) }
}

// json_body builds just the /json body string (used for the gzip path).
fn (sh &Shared) json_body(count int, m i64) string {
	mut sb := strings.new_builder(count * 224 + 32)
	sb.write_string('{"items":[')
	for i in 0 .. count {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string(sh.prefixes[i])
		sb.write_decimal(sh.dataset[i].price * sh.dataset[i].quantity * m)
		sb.write_u8(`}`)
	}
	sb.write_string('],"count":')
	sb.write_decimal(i64(count))
	sb.write_u8(`}`)
	return sb.str()
}

// fortunes queries the fortune table, appends the runtime row, sorts by message
// and renders the HTML table (escaped). 199 seeded + 1 runtime + header = 201 <tr>.
fn (mut sh Shared) fortunes() string {
	mut fortunes := []Fortune{}
	mut conn := sh.pool.acquire() or {
		return '<!doctype html><html><body><table></table></body></html>'
	}
	rows := conn.exec_param_many('SELECT id, message FROM fortune', []) or { [] }
	sh.pool.release(conn)
	for row in rows {
		fortunes << Fortune{
			id:      nn(row.vals[0]).int()
			message: nn(row.vals[1])
		}
	}
	fortunes << Fortune{
		id:      0
		message: 'Additional fortune added at request time.'
	}
	fortunes.sort(a.message < b.message)
	mut sb := strings.new_builder(32768)
	sb.write_string('<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in fortunes {
		sb.write_string('<tr><td>')
		sb.write_decimal(i64(f.id))
		sb.write_string('</td><td>')
		sb.write_string(escape_html(f.message))
		sb.write_string('</td></tr>')
	}
	sb.write_string('</table></body></html>')
	return sb.str()
}

fn escape_html(s string) string {
	return s.replace_each(['&', '&amp;', '<', '&lt;', '>', '&gt;', '"', '&quot;', "'", '&apos;'])
}

// digits returns the number of decimal digits in a non-negative integer.
fn digits(n i64) int {
	if n < 10 {
		return 1
	}
	mut x := n
	mut d := 0
	for x > 0 {
		d++
		x /= 10
	}
	return d
}

fn (mut sh Shared) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	mut conn := sh.pool.acquire() or { return '{"items":[],"count":0}' }
	rows := conn.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		[min.str(), max.str(), lim.str()]) or {
		sh.pool.release(conn)
		return '{"items":[],"count":0}'
	}
	sh.pool.release(conn)
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

// nn unwraps a nullable column value to a plain string ('' for NULL).
@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

// nn3 unwraps a nullable column value with a custom default.
@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

// qint reads a query parameter as an integer (0 if absent / non-numeric).
fn qint(req request_parser.HttpRequest, key string) i64 {
	s := req.get_query_slice(key.bytes()) or { return 0 }
	return unsafe { tos(&req.buffer[s.start], s.len) }.i64()
}

// qstr reads a query parameter as a string ('' if absent). Clones so the value
// outlives the request buffer (it is passed to the DB driver).
fn qstr(req request_parser.HttpRequest, key string) string {
	s := req.get_query_slice(key.bytes()) or { return '' }
	return unsafe { tos(&req.buffer[s.start], s.len) }.clone()
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

// body_int parses the request body as an integer, decoding chunked transfer
// encoding when present.
fn body_int(req request_parser.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	if te := req.get_header_value_slice('Transfer-Encoding') {
		val := unsafe { tos(&req.buffer[te.start], te.len) }
		if val.contains('chunked') {
			return dechunk(raw).i64()
		}
	}
	return raw.i64()
}

// dechunk decodes an HTTP/1.1 chunked body into its payload.
fn dechunk(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		nl := s.index_after('\r\n', i) or { break }
		size := strconv_hex(s[i..nl])
		if size <= 0 {
			break
		}
		data_start := nl + 2
		out.write_string(s[data_start..data_start + size])
		i = data_start + size + 2 // skip data + trailing CRLF
	}
	return out.str()
}

fn strconv_hex(s string) int {
	mut n := 0
	for c in s.trim_space() {
		d := if c >= `0` && c <= `9` {
			int(c - `0`)
		} else if c >= `a` && c <= `f` {
			int(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			int(c - `A` + 10)
		} else {
			break
		}
		n = n * 16 + d
	}
	return n
}

// ok builds a complete HTTP/1.1 response with the given content type.
fn ok(ctype string, body string) []u8 {
	mut sb := strings.new_builder(body.len + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(i64(body.len))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	sb.write_string(body)
	return sb
}

// ok_xcache builds a JSON response carrying an X-Cache: HIT|MISS header.
fn ok_xcache(ctype string, body string, cache string) []u8 {
	mut sb := strings.new_builder(body.len + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nX-Cache: ')
	sb.write_string(cache)
	sb.write_string('\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(i64(body.len))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	sb.write_string(body)
	return sb
}

// accepts_gzip reports whether the request advertises gzip in Accept-Encoding.
fn accepts_gzip(req request_parser.HttpRequest) bool {
	ae := req.get_header_value_slice('Accept-Encoding') or { return false }
	return unsafe { tos(&req.buffer[ae.start], ae.len) }.contains('gzip')
}

// content_type maps a file extension to a MIME type for the static handler.
fn content_type(name string) string {
	ext := name.all_after_last('.')
	return match ext {
		'css' { 'text/css' }
		'js' { 'application/javascript' }
		'json' { 'application/json' }
		'html' { 'text/html' }
		'svg' { 'image/svg+xml' }
		'webp' { 'image/webp' }
		'woff2' { 'font/woff2' }
		else { 'application/octet-stream' }
	}
}

// parse_db_url turns postgres://user:pass@host:port/dbname into a pg.Config.
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
		size = 200 // leave headroom under Postgres max_connections
	}
	mut pool := pg.new_connection_pool(parse_db_url(url), size)!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode([]DatasetItem, dataset_raw) or { []DatasetItem{} }

	// Precompute each item's JSON prefix once: `{…,"rating":{…},"total":`
	// (drop the closing brace, append the total key). Only the total value is
	// request-dependent, so the hot path never serializes a struct.
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	// Preload static assets into memory as ready-to-send responses (originals
	// only; skip the precompressed .gz/.br siblings — we serve identity).
	mut assets := map[string]StaticFile{}
	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	for name in os.ls(static_dir) or { []string{} } {
		if name.ends_with('.gz') || name.ends_with('.br') {
			continue
		}
		bytes := os.read_bytes('${static_dir}/${name}') or { continue }
		assets[name] = StaticFile{
			response: static_response(content_type(name), bytes)
		}
	}

	mut sh := Shared{
		pool:     pool
		dataset:  dataset
		prefixes: prefixes
		assets:   assets
		cache:    map[int]string{}
		cache_mu: sync.new_rwmutex()
	}

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: .io_uring
		limits:          http_server.Limits{
			max_request_bytes: 32 * 1024 * 1024 // accept the 20 MiB upload bodies
		}
		request_handler: fn [mut sh] (req_buffer []u8, fd int, mut out []u8) ! {
			handle(req_buffer, fd, mut out, mut sh)!
		}
	})!
	server.run()
}

// static_response prebuilds the full HTTP response for a static file.
fn static_response(ctype string, body []u8) []u8 {
	mut sb := strings.new_builder(body.len + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(i64(body.len))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	unsafe { sb.write_ptr(body.data, body.len) }
	return sb
}
