//! Proxy-Wasm module that answers the HttpArena endpoints inside veil.
//!
//! - `GET /baseline11?a=&b=`, `POST /baseline11` (the body is an integer): the sum, as `text/plain`.
//! - `GET /baseline2?a=&b=`: the sum (HTTP/2 and HTTP/3).
//! - `GET /pipeline`: `ok`.
//! - `GET /json/{count}?m=`: the first `count` items of the dataset with `total = price * quantity * m`,
//!   serialized for every request.
//!
//! The dataset comes from veil's `data_files` (`plugin_data.dataset`). It is parsed once per instance
//! (`instance_reuse = true` keeps the instance between requests) into typed fields, like nginx's
//! module; the response is written field by field for every request into a reused buffer.

use proxy_wasm::traits::*;
use proxy_wasm::types::*;
use serde::Deserialize;
use std::cell::RefCell;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Warn);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> { Box::new(Root) });
}}

#[derive(Deserialize)]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize)]
struct Item {
    id: i64,
    name: String,
    category: String,
    price: i64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: Rating,
}

/// One dataset item held as typed fields; the strings are kept JSON-escaped (with their quotes) so they are
/// re-emitted verbatim. The body is still written field by field for every request (`total` depends on `m`).
struct Row {
    id: i64,
    name: String,
    category: String,
    price: i64,
    quantity: i64,
    active: bool,
    tags: String, // `["a","b"]`
    score: i64,
    count: i64,
}

fn quoted(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

fn load(raw: &[u8]) -> Vec<Row> {
    let items: Vec<Item> = serde_json::from_slice(raw).unwrap_or_default();
    items
        .into_iter()
        .map(|it| Row {
            id: it.id,
            name: quoted(&it.name),
            category: quoted(&it.category),
            price: it.price,
            quantity: it.quantity,
            active: it.active,
            tags: serde_json::to_string(&it.tags).unwrap_or_else(|_| "[]".into()),
            score: it.rating.score,
            count: it.rating.count,
        })
        .collect()
}

fn put_i64(out: &mut Vec<u8>, v: i64) {
    let mut buf = [0u8; 20];
    let mut i = buf.len();
    let neg = v < 0;
    let mut n = v.unsigned_abs();
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    if neg {
        out.push(b'-');
    }
    out.extend_from_slice(&buf[i..]);
}

fn write_body(out: &mut Vec<u8>, rows: &[Row], m: i64) {
    out.extend_from_slice(b"{\"items\":[");
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.extend_from_slice(b"{\"id\":");
        put_i64(out, r.id);
        out.extend_from_slice(b",\"name\":");
        out.extend_from_slice(r.name.as_bytes());
        out.extend_from_slice(b",\"category\":");
        out.extend_from_slice(r.category.as_bytes());
        out.extend_from_slice(b",\"price\":");
        put_i64(out, r.price);
        out.extend_from_slice(b",\"quantity\":");
        put_i64(out, r.quantity);
        out.extend_from_slice(if r.active { b",\"active\":true,\"tags\":" } else { b",\"active\":false,\"tags\":" });
        out.extend_from_slice(r.tags.as_bytes());
        out.extend_from_slice(b",\"rating\":{\"score\":");
        put_i64(out, r.score);
        out.extend_from_slice(b",\"count\":");
        put_i64(out, r.count);
        out.extend_from_slice(b"},\"total\":");
        put_i64(out, r.price * r.quantity * m);
        out.push(b'}');
    }
    out.extend_from_slice(b"],\"count\":");
    put_i64(out, rows.len() as i64);
    out.push(b'}');
}

thread_local! {
    static DATASET: RefCell<Option<Vec<Row>>> = const { RefCell::new(None) };
    /// Response buffer reused between requests (the instance is reused, see `instance_reuse`)
    static OUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
}

struct Root;

impl Context for Root {}

impl RootContext for Root {
    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }

    fn create_http_context(&self, _context_id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(Arena))
    }
}

struct Arena;

impl Context for Arena {}

fn query_param(query: &str, name: &str) -> Option<i64> {
    query
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .find(|(k, _)| *k == name)
        .and_then(|(_, v)| v.parse().ok())
}

fn split_path(full: &str) -> (&str, &str) {
    full.split_once('?').unwrap_or((full, ""))
}

impl Arena {
    fn path(&self) -> String {
        self.get_property(vec!["request", "path"])
            .and_then(|v| String::from_utf8(v).ok())
            .unwrap_or_default()
    }

    fn text(&self, body: &[u8]) {
        self.send_http_response(200, vec![("content-type", "text/plain")], Some(body));
    }

    fn not_found(&self) {
        self.send_http_response(404, vec![("content-type", "text/plain")], Some(b"not found"));
    }

    fn sum(&self, query: &str, extra: i64) {
        let s = query_param(query, "a").unwrap_or(0) + query_param(query, "b").unwrap_or(0) + extra;
        self.text(s.to_string().as_bytes());
    }

    fn json(&self, count: &str, query: &str) {
        let Ok(count) = count.parse::<usize>() else {
            return self.not_found();
        };
        let m = query_param(query, "m").unwrap_or(1);
        DATASET.with(|d| {
            let mut d = d.borrow_mut();
            if d.is_none() {
                let raw = self.get_property(vec!["plugin_data", "dataset"]).unwrap_or_default();
                *d = Some(load(&raw));
            }
            let rows = d.as_deref().unwrap_or(&[]);
            let rows = &rows[..count.min(rows.len())];
            OUT.with(|o| {
                let mut out = o.borrow_mut();
                out.clear();
                out.reserve(512 * rows.len() + 32);
                write_body(&mut out, rows, m);
                self.send_http_response(200, vec![("content-type", "application/json")], Some(&out));
            });
        });
    }
}

impl HttpContext for Arena {
    fn on_http_request_headers(&mut self, _num_headers: usize, end_of_stream: bool) -> Action {
        let full = self.path();
        let (path, query) = split_path(&full);
        match path {
            "/baseline11" if end_of_stream => self.sum(query, 0),
            "/baseline11" => return Action::Continue, // the body phase answers
            "/baseline2" => self.sum(query, 0),
            "/pipeline" => self.text(b"ok"),
            p => match p.strip_prefix("/json/") {
                Some(count) => self.json(count, query),
                None => self.not_found(),
            },
        }
        Action::Pause
    }

    fn on_http_request_body(&mut self, body_size: usize, end_of_stream: bool) -> Action {
        if !end_of_stream {
            return Action::Pause;
        }
        let full = self.path();
        let (_, query) = split_path(&full);
        let body = self.get_http_request_body(0, body_size).unwrap_or_default();
        let n: i64 = std::str::from_utf8(&body)
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0);
        self.sum(query, n);
        Action::Pause
    }
}
