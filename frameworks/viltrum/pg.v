module main

import crypto.hmac
import crypto.pbkdf2
import crypto.rand
import crypto.sha256
import encoding.base64
import net
import net.urllib
import sync
import time
import viltrum

// Postgres for GET /async-db and GET /fortunes, with no client library: the v3 wire
// protocol and SCRAM-SHA-256 are written here. Each server connection has its own
// thread that blocks on it, so an HTTP worker never waits on a query. The worker
// takes a slot, queues it and parks the request (c.suspend); the thread writes the
// result into the slot and calls app.wake, and the worker answers from the slot.

const pg_slots = 4096 // requests in flight at once; below the engine's park_cap

const pg_sql = r'SELECT id, name, category, price, quantity, active, tags::text, rating_score, rating_count FROM items WHERE price BETWEEN $1::int AND $2::int LIMIT $3::int'

const pg_fortune_sql = 'SELECT id, message FROM fortune'

const db_empty = '{"items":[],"count":0}'.bytes()

const q_items = u8(0) // async-db

const q_fortunes = u8(1)

struct Fortune {
	id      int
	message string
}

struct PgSlot {
mut:
	state u8 // 0 free, 1 queued or running, 2 answered, 3 the request gave up
	gen   u32 = 1
	kind  u8 // q_items or q_fortunes
	min   int
	max   int
	limit int
	body  []u8      // q_items: the JSON page
	rows  []Fortune // q_fortunes: the table's rows, as read
}

@[heap]
struct Pg {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	slots []PgSlot
	free  []int
	jobs  chan int
	app   &viltrum.App = unsafe { nil }
	addr  string
	user  string
	pass  string
	db    string
	on    bool
}

// new_pg starts conns threads against url. Without a url every query answers empty.
fn new_pg(app &viltrum.App, url string, conns int) &Pg {
	mut p := &Pg{
		app:   app
		slots: []PgSlot{len: pg_slots}
		free:  []int{cap: pg_slots}
		jobs:  chan int{cap: pg_slots}
	}
	for i := pg_slots - 1; i >= 0; i-- {
		p.free << i
	}
	u := urllib.parse(url) or { return p }
	who := u.user or { return p }
	if u.host == '' {
		return p
	}
	port := if u.port() == '' { '5432' } else { u.port() }
	p.addr = '${u.hostname()}:${port}'
	p.user = who.username
	p.pass = who.password
	p.db = u.path.trim_left('/')
	p.on = true
	for _ in 0 .. conns {
		spawn pg_run(p)
	}
	return p
}

// submit queues a query of kind. 0 when there is no database or no free slot.
fn (mut p Pg) submit(kind u8, min int, max int, limit int) u64 {
	if !p.on {
		return 0
	}
	p.mu.lock()
	if p.free.len == 0 {
		p.mu.unlock()
		return 0
	}
	i := p.free.pop()
	p.slots[i].state = 1
	p.slots[i].kind = kind
	p.slots[i].min = min
	p.slots[i].max = max
	p.slots[i].limit = limit
	token := u64(p.slots[i].gen) << 32 | u64(i + 1)
	p.mu.unlock()
	p.jobs <- i // never blocks: the channel holds every slot
	return token
}

// answer writes the response for token, on the worker that parked it. An answered
// slot belongs to this request until release, so the page is built outside the lock.
fn (mut p Pg) answer(mut c viltrum.Ctx, token u64) {
	i := int(u32(token)) - 1
	p.mu.lock()
	kind := p.slots[i].kind
	if p.slots[i].state != 2 {
		p.slots[i].state = 3 // timed out; the thread frees the slot when it ends
		p.mu.unlock()
		if kind == q_fortunes {
			c.text(503, 'database unavailable')
		} else {
			c.bytes(200, 'application/json', db_empty)
		}
		return
	}
	p.mu.unlock()
	if kind == q_fortunes {
		fortunes_answer(mut c, mut p.slots[i].rows)
	} else {
		c.bytes(200, 'application/json', p.slots[i].body)
	}
	p.mu.lock()
	p.release(i)
	p.mu.unlock()
}

// release frees slot i; p.mu is held. The new generation keeps a late wake for the
// old request from answering the next one.
fn (mut p Pg) release(i int) {
	p.slots[i].state = 0
	p.slots[i].gen++
	if p.slots[i].gen == 0 {
		p.slots[i].gen = 1
	}
	p.free << i
}

// done hands slot i back from its thread, and wakes the request if it still waits.
fn (mut p Pg) done(i int) {
	p.mu.lock()
	if p.slots[i].state == 3 {
		p.release(i)
		p.mu.unlock()
		return
	}
	p.slots[i].state = 2
	token := u64(p.slots[i].gen) << 32 | u64(i + 1)
	p.mu.unlock()
	p.app.wake(token)
}

// pg_run owns one server connection: it reconnects when the connection breaks and
// answers a failed query empty.
fn pg_run(pp &Pg) {
	mut p := unsafe { pp }
	mut wb := []u8{cap: 256}
	for {
		mut c := pg_connect(p) or {
			time.sleep(100 * time.millisecond)
			continue
		}
		for {
			i := <-p.jobs
			if p.slots[i].kind == q_fortunes {
				// no rows (an error, or a connection without the table) answers 503
				ok := c.fortunes(mut wb, mut p.slots[i].rows) or {
					p.slots[i].rows.clear()
					p.done(i)
					break
				}
				if !ok {
					p.slots[i].rows.clear()
				}
				p.done(i)
				continue
			}
			ok := c.query(mut wb, p.slots[i].min, p.slots[i].max, p.slots[i].limit, mut
				p.slots[i].body) or {
				p.slots[i].body.clear()
				p.slots[i].body << db_empty
				p.done(i)
				break
			}
			if !ok {
				p.slots[i].body.clear()
				p.slots[i].body << db_empty
			}
			p.done(i)
		}
		c.sock.close() or {}
	}
}

struct PgConn {
mut:
	sock &net.TcpConn = unsafe { nil }
	rb   []u8         = []u8{len: 65536}
	off  int
	end  int
}

fn be32(b []u8, at int) int {
	return int(u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]))
}

fn put32(mut b []u8, v int) {
	b << u8(v >> 24)
	b << u8(v >> 16)
	b << u8(v >> 8)
	b << u8(v)
}

fn put16(mut b []u8, v int) {
	b << u8(v >> 8)
	b << u8(v)
}

fn put_cstr(mut b []u8, s string) {
	unsafe { b.push_many(s.str, s.len) }
	b << 0
}

// msg starts a frontend message of type t; seal writes its length.
fn msg(mut b []u8, t u8) int {
	b << t
	at := b.len
	put32(mut b, 0)
	return at
}

fn seal(mut b []u8, at int) {
	n := b.len - at
	b[at] = u8(n >> 24)
	b[at + 1] = u8(n >> 16)
	b[at + 2] = u8(n >> 8)
	b[at + 3] = u8(n)
}

// next is the next backend message: its type and body, a view into c.rb that the
// following call may overwrite.
fn (mut c PgConn) next() !(u8, []u8) {
	for {
		have := c.end - c.off
		if have >= 5 {
			n := be32(c.rb, c.off + 1)
			if n < 4 || 1 + n > c.rb.len {
				// shortcut: messages over 64 KiB are refused; rows here are under 1 KiB
				return error('postgres: message of ${n} bytes')
			}
			if have >= 1 + n {
				t := c.rb[c.off]
				body := unsafe { c.rb[c.off + 5..c.off + 1 + n] }
				c.off += 1 + n
				return t, body
			}
		}
		if c.off > 0 {
			unsafe { C.memmove(&c.rb[0], &c.rb[c.off], have) }
			c.off = 0
			c.end = have
		}
		m := c.sock.read_ptr(&c.rb[c.end], c.rb.len - c.end)!
		if m <= 0 {
			return error('postgres: connection closed')
		}
		c.end += m
	}
	return error('postgres: unreachable')
}

// pg_error is an ErrorResponse's message (its M field).
fn pg_error(body []u8) IError {
	mut i := 0
	for i < body.len && body[i] != 0 {
		t := body[i]
		mut j := i + 1
		for j < body.len && body[j] != 0 {
			j++
		}
		if t == `M` {
			return error('postgres: ' + body[i + 1..j].bytestr())
		}
		i = j + 1
	}
	return error('postgres: error')
}

// wait reads to ReadyForQuery, failing on an ErrorResponse.
fn (mut c PgConn) wait() ! {
	mut failed := false
	mut why := IError(error(''))
	for {
		t, body := c.next()!
		if t == `E` {
			failed = true
			why = pg_error(body)
		} else if t == `Z` {
			break
		}
	}
	if failed {
		return why
	}
}

fn pg_connect(p &Pg) !&PgConn {
	mut c := &PgConn{
		sock: net.dial_tcp(p.addr)!
	}
	mut b := []u8{}
	put32(mut b, 0)
	put32(mut b, 196608) // protocol 3.0
	put_cstr(mut b, 'user')
	put_cstr(mut b, p.user)
	put_cstr(mut b, 'database')
	put_cstr(mut b, p.db)
	b << 0
	seal(mut b, 0)
	c.sock.write(b) or {
		c.sock.close() or {}
		return err
	}
	c.login(p.pass) or {
		c.sock.close() or {}
		return err
	}
	// the query is parsed once per connection
	b.clear()
	mut at := msg(mut b, `P`)
	put_cstr(mut b, 'adb')
	put_cstr(mut b, pg_sql)
	put16(mut b, 0)
	seal(mut b, at)
	at = msg(mut b, `S`)
	seal(mut b, at)
	c.sock.write(b) or {
		c.sock.close() or {}
		return err
	}
	c.wait() or {
		c.sock.close() or {}
		return err
	}
	// fortunes' query on its own Sync: a database without the table still serves async-db
	b.clear()
	at = msg(mut b, `P`)
	put_cstr(mut b, 'fts')
	put_cstr(mut b, pg_fortune_sql)
	put16(mut b, 0)
	seal(mut b, at)
	at = msg(mut b, `S`)
	seal(mut b, at)
	c.sock.write(b) or {
		c.sock.close() or {}
		return err
	}
	c.wait() or {}
	return c
}

// login answers the server's authentication request: none (trust) or SCRAM-SHA-256.
fn (mut c PgConn) login(pass string) ! {
	mut bare := ''
	mut auth := ''
	mut salted := []u8{}
	mut b := []u8{}
	for {
		t, body := c.next()!
		if t == `E` {
			return pg_error(body)
		}
		if t == `Z` {
			return
		}
		if t != `R` {
			continue // ParameterStatus, BackendKeyData, notices
		}
		code := be32(body, 0)
		b.clear()
		match code {
			0 {}
			10 {
				if !body[4..].bytestr().contains('SCRAM-SHA-256') {
					return error('postgres: no SCRAM-SHA-256')
				}
				bare = 'n=,r=' + base64.encode(rand.bytes(18)!)
				client_first := 'n,,' + bare
				at := msg(mut b, `p`)
				put_cstr(mut b, 'SCRAM-SHA-256')
				put32(mut b, client_first.len)
				unsafe { b.push_many(client_first.str, client_first.len) }
				seal(mut b, at)
				c.sock.write(b)!
			}
			11 {
				// shortcut: the password is not SASLprep-normalised; fine for ASCII ones
				server_first := body[4..].bytestr()
				mut nonce := ''
				mut salt := []u8{}
				mut iter := 0
				for kv in server_first.split(',') {
					if kv.starts_with('r=') {
						nonce = kv[2..]
					} else if kv.starts_with('s=') {
						salt = base64.decode(kv[2..])
					} else if kv.starts_with('i=') {
						iter = kv[2..].int()
					}
				}
				if !nonce.starts_with(bare[5..]) || iter < 1 || iter > 1_000_000 {
					return error('postgres: bad SCRAM challenge')
				}
				salted = pbkdf2.key(pass.bytes(), salt, iter, 32, sha256.new())!
				client_key := hmac.new(salted, 'Client Key'.bytes(), sha256.sum, sha256.block_size)
				stored := sha256.sum(client_key)
				without_proof := 'c=biws,r=' + nonce
				auth = bare + ',' + server_first + ',' + without_proof
				mut proof := hmac.new(stored, auth.bytes(), sha256.sum, sha256.block_size)
				for i in 0 .. proof.len {
					proof[i] ^= client_key[i]
				}
				final := without_proof + ',p=' + base64.encode(proof)
				at := msg(mut b, `p`)
				unsafe { b.push_many(final.str, final.len) }
				seal(mut b, at)
				c.sock.write(b)!
			}
			12 {
				server_key := hmac.new(salted, 'Server Key'.bytes(), sha256.sum, sha256.block_size)
				want := 'v=' +
					base64.encode(hmac.new(server_key, auth.bytes(), sha256.sum, sha256.block_size))
				if body[4..].bytestr().trim_space() != want {
					return error('postgres: the server did not prove the password')
				}
			}
			else {
				return error('postgres: authentication method ${code} is not supported')
			}
		}
	}
}

// query runs the prepared statement and writes the JSON page to out. false when
// the server answered with an error; the connection is still usable then.
fn (mut c PgConn) query(mut b []u8, min int, max int, limit int, mut out []u8) !bool {
	b.clear()
	mut at := msg(mut b, `B`)
	put_cstr(mut b, '') // unnamed portal
	put_cstr(mut b, 'adb')
	put16(mut b, 0) // parameters in text
	put16(mut b, 3)
	for v in [min, max, limit]! {
		p := b.len
		put32(mut b, 0)
		add_int(mut b, v)
		b[p + 3] = u8(b.len - p - 4) // at most 11 digits
	}
	put16(mut b, 0) // results in text
	seal(mut b, at)
	at = msg(mut b, `E`)
	put_cstr(mut b, '')
	put32(mut b, 0)
	seal(mut b, at)
	at = msg(mut b, `S`)
	seal(mut b, at)
	c.sock.write(b)!
	out.clear()
	add(mut out, '{"items":[')
	mut rows := 0
	mut ok := true
	for {
		t, body := c.next()!
		if t == `D` {
			if rows > 0 {
				out << `,`
			}
			row_json(body, mut out)
			rows++
		} else if t == `E` {
			ok = false
		} else if t == `Z` {
			break
		}
	}
	add(mut out, '],"count":')
	add_int(mut out, rows)
	out << `}`
	return ok
}

// fortunes runs the prepared fortune query into rows. false when the server
// answered with an error.
fn (mut c PgConn) fortunes(mut b []u8, mut rows []Fortune) !bool {
	b.clear()
	mut at := msg(mut b, `B`)
	put_cstr(mut b, '')
	put_cstr(mut b, 'fts')
	put16(mut b, 0)
	put16(mut b, 0)
	put16(mut b, 0)
	seal(mut b, at)
	at = msg(mut b, `E`)
	put_cstr(mut b, '')
	put32(mut b, 0)
	seal(mut b, at)
	at = msg(mut b, `S`)
	seal(mut b, at)
	c.sock.write(b)!
	rows.clear()
	mut ok := true
	for {
		t, body := c.next()!
		if t == `D` {
			// two text columns: id, message
			n := be32(body, 2)
			mut id := 0
			for k in 0 .. n {
				id = id * 10 + int(body[6 + k] - `0`)
			}
			at2 := 6 + if n > 0 { n } else { 0 }
			m := be32(body, at2)
			msg_ := if m > 0 { body[at2 + 4..at2 + 4 + m].bytestr() } else { '' }
			rows << Fortune{id, msg_}
		} else if t == `E` {
			ok = false
		} else if t == `Z` {
			break
		}
	}
	return ok
}

const row_keys = ['{"id":', ',"name":', ',"category":', ',"price":', ',"quantity":', ',"active":',
	',"tags":', ',"rating":{"score":', ',"count":']

// row_json writes one DataRow of pg_sql as an item. Text columns are quoted, the
// numbers and the tags (jsonb as text) go in as Postgres printed them.
fn row_json(body []u8, mut out []u8) {
	mut at := 2 // after the column count
	for col in 0 .. 9 {
		n := be32(body, at)
		at += 4
		add(mut out, row_keys[col])
		v := if n < 0 { []u8{} } else { body[at..at + n] }
		if n > 0 {
			at += n
		}
		match col {
			1, 2 { json_str(v, mut out) }
			5 { add(mut out, if v.len > 0 && v[0] == `t` { 'true' } else { 'false' }) }
			6 { add_or(mut out, v, '[]') }
			else { add_or(mut out, v, '0') }
		}
	}
	add(mut out, '}}')
}

fn add(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// add_or writes v, or def for a NULL or empty value.
fn add_or(mut out []u8, v []u8, def string) {
	if v.len == 0 {
		add(mut out, def)
	} else {
		unsafe { out.push_many(v.data, v.len) }
	}
}

fn add_int(mut out []u8, v int) {
	if v < 0 {
		out << `-`
	}
	mut u := if v < 0 { u64(-i64(v)) } else { u64(v) }
	mut d := [10]u8{}
	mut n := 0
	for {
		d[n] = u8(`0` + u % 10)
		n++
		u /= 10
		if u == 0 {
			break
		}
	}
	for n > 0 {
		n--
		out << d[n]
	}
}

fn json_str(v []u8, mut out []u8) {
	out << `"`
	for ch in v {
		if ch == `"` || ch == `\\` {
			out << `\\`
			out << ch
		} else if ch < 0x20 {
			add(mut out, '\\u00')
			out << '0123456789abcdef'[ch >> 4]
			out << '0123456789abcdef'[ch & 15]
		} else {
			out << ch
		}
	}
	out << `"`
}
