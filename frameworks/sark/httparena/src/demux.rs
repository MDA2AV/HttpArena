use sark_core::http::codec::Parse;
use sark_core::http::head::{BytesScan, header_lines};
use sark_grpc::server::{H2_PREFACE, is_h2_preface_prefix};

use crate::demux8080::Lane;

const MAX_SNIFF_BYTES: usize = 16 * 1024;

pub(crate) fn sniff(buf: &[u8]) -> Option<Lane> {
    if is_h2_preface_prefix(buf) {
        if buf.len() >= H2_PREFACE.len() {
            return Some(Lane::Grpc);
        }
        return None;
    }

    let Some(line_end) = BytesScan::find_crlf_from(buf, 0) else {
        return h1_or_more(buf);
    };

    match request_segment(&buf[..line_end]) {
        Some(seg) if seg == b"/ws" => {}
        _ => return Some(Lane::H1),
    }

    let Some(head) = Parse::find_double_crlf(buf) else {
        return h1_or_more(buf);
    };

    if has_upgrade_websocket(&buf[line_end + 2..head.start + 2]) {
        Some(Lane::Ws)
    } else {
        Some(Lane::H1)
    }
}

fn h1_or_more(buf: &[u8]) -> Option<Lane> {
    if buf.len() > MAX_SNIFF_BYTES {
        Some(Lane::H1)
    } else {
        None
    }
}

fn request_segment(line: &[u8]) -> Option<&[u8]> {
    let first_sp = line.iter().position(|&b| b == b' ')?;
    let rest = &line[first_sp + 1..];
    let second_sp = rest.iter().position(|&b| b == b' ')?;
    let target = &rest[..second_sp];
    let end = target
        .iter()
        .position(|&b| b == b'?')
        .unwrap_or(target.len());
    Some(&target[..end])
}

fn has_upgrade_websocket(headers: &[u8]) -> bool {
    header_lines(headers).any(|(name, value)| {
        name.eq_ignore_ascii_case(b"upgrade") && value.eq_ignore_ascii_case(b"websocket")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_needs_more() {
        assert_eq!(sniff(b""), None);
    }

    #[test]
    fn ambiguous_p_defers() {
        assert_eq!(sniff(b"P"), None);
        assert_eq!(sniff(b"PRI"), None);
        assert_eq!(sniff(b"PRI * HTTP/2.0\r\n\r\nSM\r\n"), None);
    }

    #[test]
    fn post_is_not_preface() {
        assert_eq!(sniff(b"PO"), None);
        assert_eq!(sniff(b"POST /json/1 HTTP/1.1\r\n\r\n"), Some(Lane::H1));
    }

    #[test]
    fn full_preface_is_grpc() {
        assert_eq!(sniff(H2_PREFACE), Some(Lane::Grpc));
        let mut more = H2_PREFACE.to_vec();
        more.extend_from_slice(b"\x00\x00\x00\x04\x00");
        assert_eq!(sniff(&more), Some(Lane::Grpc));
    }

    #[test]
    fn preface_split_defers_then_resolves() {
        assert_eq!(sniff(&H2_PREFACE[..10]), None);
        assert_eq!(sniff(&H2_PREFACE[..23]), None);
        assert_eq!(sniff(&H2_PREFACE[..24]), Some(Lane::Grpc));
    }

    #[test]
    fn plain_h1_root() {
        assert_eq!(sniff(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"), Some(Lane::H1));
        assert_eq!(sniff(b"GET /json/1 HTTP/1.1\r\n\r\n"), Some(Lane::H1));
    }

    #[test]
    fn h1_request_line_incomplete_defers() {
        assert_eq!(sniff(b"GET /js"), None);
        assert_eq!(sniff(b"GET / HTTP/1.1\r"), None);
    }

    #[test]
    fn non_ws_path_decides_h1_immediately() {
        assert_eq!(sniff(b"GET /json/1 HTTP/1.1\r\n"), Some(Lane::H1));
    }

    #[test]
    fn ws_path_with_upgrade_is_ws() {
        let req =
            b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
        assert_eq!(sniff(req), Some(Lane::Ws));
    }

    #[test]
    fn ws_upgrade_case_insensitive() {
        let req = b"GET /ws HTTP/1.1\r\nupgrade:  WebSocket  \r\n\r\n";
        assert_eq!(sniff(req), Some(Lane::Ws));
    }

    #[test]
    fn ws_path_no_upgrade_is_h1() {
        let req = b"GET /ws HTTP/1.1\r\nHost: x\r\n\r\n";
        assert_eq!(sniff(req), Some(Lane::H1));
    }

    #[test]
    fn ws_path_headers_incomplete_defers() {
        assert_eq!(sniff(b"GET /ws HTTP/1.1\r\n"), None);
        assert_eq!(sniff(b"GET /ws HTTP/1.1\r\nUpgrade: websock"), None);
    }

    #[test]
    fn ws_with_query_is_ws() {
        let req = b"GET /ws?room=1 HTTP/1.1\r\nUpgrade: websocket\r\n\r\n";
        assert_eq!(sniff(req), Some(Lane::Ws));
    }

    #[test]
    fn pipelined_first_root_is_h1() {
        let req = b"GET / HTTP/1.1\r\n\r\nGET /json/1 HTTP/1.1\r\n\r\n";
        assert_eq!(sniff(req), Some(Lane::H1));
    }
}
