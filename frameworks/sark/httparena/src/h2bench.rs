use std::collections::HashMap;

use o3::buffer::Owned;
use sark_h2::ServerRole;
use sark_h2::conn::{Conn, Event};
use sark_h2::hpack::Header;

use crate::json::JsonOut;
use crate::static_files::StaticEntry;

pub struct BenchHandler {
    statics: Option<&'static HashMap<&'static str, StaticEntry>>,
}

impl BenchHandler {
    pub fn new() -> Self {
        Self { statics: None }
    }

    pub fn with_statics(statics: &'static HashMap<&'static str, StaticEntry>) -> Self {
        Self {
            statics: Some(statics),
        }
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
            return (b"200", b"application/json", JsonOut::items_body(count, m));
        }
        let mut body = Owned::with_capacity(24);
        body.extend_from_slice(br#"{"error":"not found"}"#);
        (b"404", b"application/json", body)
    }

    fn send(
        conn: &mut Conn<ServerRole>,
        stream_id: sark_h2::StreamId,
        status: &[u8],
        ctype: &[u8],
        content_encoding: &[u8],
        body: &[u8],
    ) {
        let encoded = !content_encoding.is_empty() && content_encoding != b"identity";
        let resp_full = [
            Header {
                name: b":status",
                value: status,
            },
            Header {
                name: b"content-type",
                value: ctype,
            },
            Header {
                name: b"content-encoding",
                value: content_encoding,
            },
        ];
        let resp: &[Header] = if encoded { &resp_full } else { &resp_full[..2] };
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
            let entry = self
                .statics
                .and_then(|m| std::str::from_utf8(file).ok().and_then(|k| m.get(k)));
            match entry {
                Some(e) => {
                    let ae = headers
                        .iter()
                        .find(|h| h.name == b"accept-encoding")
                        .map(|h| h.value.as_slice())
                        .unwrap_or(b"");
                    let (body, encoding) = e.select(ae);
                    Self::send(
                        conn,
                        stream_id,
                        b"200",
                        e.content_type.as_bytes(),
                        encoding.as_bytes(),
                        body,
                    );
                }
                None => Self::send(conn, stream_id, b"404", b"text/plain", b"", b""),
            }
            return;
        }
        let (status, ctype, body) = Self::route(path);
        Self::send(conn, stream_id, status, ctype, b"", &body);
    }
}
