use std::future::{Ready, ready};

use dope::fiber::Fiber;
use o3::buffer::{Owned, Shared};
use sark::fs::ServeDir;
use sark_h2::hpack::OwnedHeader;
use sark_h2::server::{Handler, Request, Response};

use crate::json::JsonOut;

pub struct BenchHandler {
    serve: Option<&'static ServeDir>,
    advertise_h3: bool,
}

impl BenchHandler {
    pub fn new() -> Self {
        Self {
            serve: None,
            advertise_h3: false,
        }
    }

    pub fn with_serve(serve: &'static ServeDir) -> Self {
        Self {
            serve: Some(serve),
            advertise_h3: false,
        }
    }

    pub fn advertise_h3(mut self, on: bool) -> Self {
        self.advertise_h3 = on;
        self
    }

    pub fn route(path: &[u8]) -> (&'static [u8], &'static [u8], Owned) {
        let (seg, query) = match path.iter().position(|&b| b == b'?') {
            Some(q) => (&path[..q], &path[q + 1..]),
            None => (path, &b""[..]),
        };
        if seg == b"/baseline2" {
            let a = Self::query_u64(query, b"a");
            let b = Self::query_u64(query, b"b");
            return (b"200", b"text/plain", JsonOut::sum_body(a, b));
        }
        if let Some(rest) = seg.strip_prefix(b"/json/") {
            let count = Self::parse_u64(rest) as usize;
            let m = Self::query_u64(query, b"m");
            return (b"200", b"application/json", JsonOut::items_standard(count, m));
        }
        let mut body = Owned::with_capacity(24);
        body.extend_from_slice(br#"{"error":"not found"}"#);
        (b"404", b"application/json", body)
    }

    fn status_bytes(code: u16) -> &'static [u8] {
        match code {
            200 => b"200",
            404 => b"404",
            500 => b"500",
            _ => b"200",
        }
    }

    fn wire_header_value<'a>(wire: &'a [u8], name: &[u8]) -> Option<&'a [u8]> {
        for line in wire.split(|&b| b == b'\n') {
            let line = line.strip_suffix(b"\r").unwrap_or(line);
            if line.is_empty() {
                continue;
            }
            let Some(colon) = line.iter().position(|&b| b == b':') else {
                continue;
            };
            let key = line[..colon].trim_ascii();
            if key.eq_ignore_ascii_case(name) {
                return Some(line[colon + 1..].trim_ascii());
            }
        }
        None
    }

    fn build(&self, status: &[u8], ctype: &[u8], content_encoding: &[u8], body: Shared) -> Response {
        let encoded = !content_encoding.is_empty() && content_encoding != b"identity";
        let mut headers = Vec::with_capacity(4);
        headers.push(OwnedHeader::new(b":status", status));
        headers.push(OwnedHeader::new(b"content-type", ctype));
        if encoded {
            headers.push(OwnedHeader::new(b"content-encoding", content_encoding));
        }
        if self.advertise_h3 {
            headers.push(OwnedHeader::new(b"alt-svc", b"h3=\":8443\"; ma=86400"));
        }
        Response::new(headers, body)
    }

    fn respond(&self, req: &Request) -> Response {
        let path = req
            .headers
            .iter()
            .find(|h| h.name == b":path")
            .map(|h| h.value.as_slice())
            .unwrap_or(b"/");
        let seg = match path.iter().position(|&b| b == b'?') {
            Some(q) => &path[..q],
            None => path,
        };
        if let Some(file) = seg.strip_prefix(b"/static/") {
            return match self.serve {
                Some(serve) => {
                    let ae = req
                        .headers
                        .iter()
                        .find(|h| h.name == b"accept-encoding")
                        .map(|h| h.value.as_slice())
                        .unwrap_or(b"");
                    let resp = serve.serve(file, ae);
                    let status = Self::status_bytes(resp.status().as_u16());
                    let ctype = resp
                        .headers()
                        .get("content-type")
                        .map(|v| v.as_bytes())
                        .unwrap_or(b"application/octet-stream");
                    let encoding =
                        Self::wire_header_value(resp.wire_headers(), b"content-encoding")
                            .unwrap_or(b"");
                    let body = Shared::from(resp.body().to_vec());
                    self.build(status, ctype, encoding, body)
                }
                None => self.build(b"404", b"text/plain", b"", Shared::from(Vec::new())),
            };
        }
        let (status, ctype, body) = Self::route(path);
        self.build(status, ctype, b"", body.freeze())
    }

    fn query_u64(query: &[u8], key: &[u8]) -> u64 {
        for pair in query.split(|&b| b == b'&') {
            if let Some(eq) = pair.iter().position(|&b| b == b'=')
                && &pair[..eq] == key
            {
                return Self::parse_u64(&pair[eq + 1..]);
            }
        }
        0
    }

    fn parse_u64(bytes: &[u8]) -> u64 {
        let mut acc: u64 = 0;
        for &b in bytes {
            if b.is_ascii_digit() {
                acc = acc.wrapping_mul(10).wrapping_add((b - b'0') as u64);
            } else {
                break;
            }
        }
        acc
    }
}

impl Default for BenchHandler {
    fn default() -> Self {
        Self::new()
    }
}

impl Handler for BenchHandler {
    type Fut<'h> = Ready<Response>;

    fn on_request<'h>(&'h self, req: Request) -> Fiber<'h, Self::Fut<'h>> {
        Fiber::new(ready(self.respond(&req)))
    }
}
