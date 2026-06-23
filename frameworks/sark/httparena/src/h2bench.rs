use o3::buffer::Owned;
use sark::fs::ServeDir;
use sark_h2::ServerRole;
use sark_h2::conn::{Conn, Event};
use sark_h2::hpack::Header;

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

    fn send(
        conn: &mut Conn<ServerRole>,
        stream_id: sark_h2::StreamId,
        status: &[u8],
        ctype: &[u8],
        content_encoding: &[u8],
        body: &[u8],
        advertise_h3: bool,
    ) {
        let encoded = !content_encoding.is_empty() && content_encoding != b"identity";
        let mut resp_buf = [Header {
            name: b":status",
            value: status,
        }; 4];
        resp_buf[1] = Header {
            name: b"content-type",
            value: ctype,
        };
        let mut n = 2;
        if encoded {
            resp_buf[n] = Header {
                name: b"content-encoding",
                value: content_encoding,
            };
            n += 1;
        }
        if advertise_h3 {
            resp_buf[n] = Header {
                name: b"alt-svc",
                value: b"h3=\":8443\"; ma=86400",
            };
            n += 1;
        }
        let resp: &[Header] = &resp_buf[..n];
        if conn
            .send_response(stream_id, resp, body.is_empty())
            .is_err()
        {
            return;
        }
        let mut off = 0;
        while off < body.len() {
            match conn.send_data(stream_id, &body[off..], true) {
                Ok(0) => break,
                Ok(n) => off += n,
                Err(_) => break,
            }
        }
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

impl sark_h2::server::Handler for BenchHandler {
    fn on_event(&mut self, event: Event, conn: &mut Conn<ServerRole>) {
        let Event::Headers {
            stream_id,
            headers,
            trailing,
            ..
        } = event
        else {
            return;
        };
        if trailing {
            return;
        }
        let path = headers
            .iter()
            .find(|h| h.name == b":path")
            .map(|h| h.value.as_slice())
            .unwrap_or(b"/");
        let seg = match path.iter().position(|&b| b == b'?') {
            Some(q) => &path[..q],
            None => path,
        };
        if let Some(file) = seg.strip_prefix(b"/static/") {
            match self.serve {
                Some(serve) => {
                    let ae = headers
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
                    Self::send(
                        conn,
                        stream_id,
                        status,
                        ctype,
                        encoding,
                        resp.body(),
                        self.advertise_h3,
                    );
                }
                None => Self::send(
                    conn,
                    stream_id,
                    b"404",
                    b"text/plain",
                    b"",
                    b"",
                    self.advertise_h3,
                ),
            }
            return;
        }
        let (status, ctype, body) = Self::route(path);
        Self::send(
            conn,
            stream_id,
            status,
            ctype,
            b"",
            &body,
            self.advertise_h3,
        );
    }
}
