use std::future::{Ready, ready};

use dope::fiber::Fiber;
use o3::buffer::{Owned, Shared};
use sark::fs::ServeDir;
use sark_core::http::head::header_lines;
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
            return (
                b"200",
                b"application/json",
                JsonOut::items_standard(count, m),
            );
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
        header_lines(wire).find_map(|(key, value)| key.eq_ignore_ascii_case(name).then_some(value))
    }

    fn build(
        &self,
        status: &[u8],
        ctype: &[u8],
        content_encoding: &[u8],
        body: Shared,
    ) -> Response {
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

    fn grpc_status_bytes(code: u8) -> &'static [u8] {
        const TABLE: [&[u8]; 17] = [
            b"0", b"1", b"2", b"3", b"4", b"5", b"6", b"7", b"8", b"9", b"10", b"11", b"12", b"13",
            b"14", b"15", b"16",
        ];
        TABLE.get(code as usize).copied().unwrap_or(b"2")
    }

    fn grpc_reply(&self, path: &[u8], body: &[u8]) -> Response {
        let (frames, status) = crate::grpcbench::dispatch(path, body);
        let headers = vec![
            OwnedHeader::new(b":status", b"200"),
            OwnedHeader::new(b"content-type", b"application/grpc"),
        ];
        let mut response = Response::new(headers, Shared::from(frames));
        response.trailers.push(OwnedHeader::new(
            b"grpc-status",
            Self::grpc_status_bytes(status.code().as_u8()),
        ));
        let message = status.message();
        if !message.is_empty() {
            response
                .trailers
                .push(OwnedHeader::new(b"grpc-message", message.as_bytes()));
        }
        response
    }

    fn respond(&self, req: &Request) -> Response {
        let mut path: &[u8] = b"/";
        let mut ctype: &[u8] = b"";
        for h in &req.headers {
            if h.name == b":path" {
                path = h.value.as_slice();
            } else if h.name == b"content-type" {
                ctype = h.value.as_slice();
            }
        }
        if ctype.starts_with(b"application/grpc") {
            return self.grpc_reply(path, &req.body);
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;
    use sark_grpc::frame::{Deframer, MessageFrame};

    use crate::grpcbench::{SumReply, SumRequest};

    fn header(name: &[u8], value: &[u8]) -> OwnedHeader {
        OwnedHeader::new(name, value)
    }

    #[test]
    fn grpc_request_yields_framed_reply_with_status_trailer() {
        let mut payload = Vec::new();
        SumRequest { a: 20, b: 22 }.encode(&mut payload).unwrap();
        let mut body = Vec::new();
        MessageFrame::encode(false, &payload, &mut body).unwrap();

        let handler = BenchHandler::new();
        let response = handler.grpc_reply(b"/benchmark.BenchmarkService/GetSum", &body);
        assert!(
            response
                .headers
                .iter()
                .any(|h| h.name == b"content-type" && h.value == b"application/grpc")
        );
        assert!(
            response
                .trailers
                .iter()
                .any(|h| h.name == b"grpc-status" && h.value == b"0")
        );

        let mut deframer = Deframer::new(1 << 20);
        let mut messages = Vec::new();
        deframer
            .push(response.body.as_ref(), &mut messages)
            .unwrap();
        assert_eq!(messages.len(), 1);
        let reply = SumReply::decode(messages[0].payload.as_slice()).unwrap();
        assert_eq!(reply.result, 42);
    }

    #[test]
    fn non_grpc_request_falls_through() {
        let req = Request {
            headers: vec![header(b":path", b"/baseline2")],
            body: Vec::new(),
        };
        let response = BenchHandler::new().respond(&req);
        assert!(
            response
                .headers
                .iter()
                .any(|h| h.name == b"content-type" && h.value != b"application/grpc")
        );
    }
}
