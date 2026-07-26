module main

import picoev
import picohttpparser
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

struct Shared {
mut:
	dataset  []DatasetItem
	prefixes []string
}

fn callback(data voidptr, req picohttpparser.Request, mut res picohttpparser.Response) {
	sh := unsafe { &Shared(data) }
	route := req.path.all_before('?')

	if route == '/pipeline' {
		res.http_ok()
		res.header_server()
		res.plain()
		res.body('ok')
	} else if route == '/baseline11' {
		mut sum := qint(req.path, 'a') + qint(req.path, 'b')
		if req.method == 'POST' {
			sum += body_int(req)
		}
		res.http_ok()
		res.header_server()
		res.plain()
		res.body(sum.str())
	} else if route == '/upload' {
		res.http_ok()
		res.header_server()
		res.plain()
		res.body(req.body.len.str())
	} else if route.starts_with('/json/') {
		count := clamp_count(route[6..].i64(), sh.dataset.len)
		mut m := qint(req.path, 'm')
		if m == 0 {
			m = 1
		}
		res.http_ok()
		res.header_server()
		res.json()
		res.body(sh.json_body(count, m))
	} else {
		res.http_404()
	}
	res.end()
}

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

fn body_int(req picohttpparser.Request) i64 {
	if req.body.len == 0 {
		return 0
	}
	mut chunked := false
	for i in 0 .. req.num_headers {
		h := req.headers[i]
		if h.name.to_lower() == 'transfer-encoding' && h.value.contains('chunked') {
			chunked = true
			break
		}
	}
	if chunked {
		return dechunk(req.body).i64()
	}
	return req.body.i64()
}

fn dechunk(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		nl := s.index_after('\r\n', i) or { break }
		size := hex_int(s[i..nl])
		if size <= 0 {
			break
		}
		ds := nl + 2
		out.write_string(s[ds..ds + size])
		i = ds + size + 2
	}
	return out.str()
}

fn hex_int(s string) int {
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

fn qint(target string, key string) i64 {
	needle := key + '='
	idx := target.index(needle) or { return 0 }
	rest := target[idx + needle.len..]
	endp := rest.index('&') or { rest.len }
	return rest[..endp].i64()
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

fn main() {
	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset := json.decode([]DatasetItem, os.read_file(dataset_path) or { '[]' }) or {
		[]DatasetItem{}
	}
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	mut sh := &Shared{
		dataset:  dataset
		prefixes: prefixes
	}

	mut server := picoev.new(
		port:      8080
		cb:        callback
		user_data: sh
		max_write: 131072
	)!
	server.serve()
}
