const H2_PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const MAX_SNIFF_BYTES: usize = 16 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Grpc,
    Ws,
    H1,
    NeedMore,
}

pub fn sniff(buf: &[u8]) -> Decision {
    let n = buf.len().min(H2_PREFACE.len());
    if buf[..n] == H2_PREFACE[..n] {
        if buf.len() >= H2_PREFACE.len() {
            return Decision::Grpc;
        }
        return Decision::NeedMore;
    }

    let Some(line_end) = find_crlf(buf) else {
        return if buf.len() > MAX_SNIFF_BYTES {
            Decision::H1
        } else {
            Decision::NeedMore
        };
    };

    match request_segment(&buf[..line_end]) {
        Some(seg) if seg == b"/ws" => {}
        Some(_) => return Decision::H1,
        None => return Decision::H1,
    }

    let Some(head_end) = find_double_crlf(buf) else {
        return if buf.len() > MAX_SNIFF_BYTES {
            Decision::H1
        } else {
            Decision::NeedMore
        };
    };

    if has_upgrade_websocket(&buf[line_end + 2..head_end]) {
        Decision::Ws
    } else {
        Decision::H1
    }
}

fn find_crlf(buf: &[u8]) -> Option<usize> {
    let mut i = 0;
    while i + 1 < buf.len() {
        if buf[i] == b'\r' && buf[i + 1] == b'\n' {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    let mut i = 0;
    while i + 3 < buf.len() {
        if buf[i] == b'\r' && buf[i + 1] == b'\n' && buf[i + 2] == b'\r' && buf[i + 3] == b'\n' {
            return Some(i + 2);
        }
        i += 1;
    }
    None
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
    for line in headers.split(|&b| b == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        let Some(colon) = line.iter().position(|&b| b == b':') else {
            continue;
        };
        let name = trim(&line[..colon]);
        if name.eq_ignore_ascii_case(b"upgrade") {
            let value = trim(&line[colon + 1..]);
            if value.eq_ignore_ascii_case(b"websocket") {
                return true;
            }
        }
    }
    false
}

fn trim(mut s: &[u8]) -> &[u8] {
    while let [first, rest @ ..] = s {
        if first.is_ascii_whitespace() {
            s = rest;
        } else {
            break;
        }
    }
    while let [rest @ .., last] = s {
        if last.is_ascii_whitespace() {
            s = rest;
        } else {
            break;
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_needs_more() {
        assert_eq!(sniff(b""), Decision::NeedMore);
    }

    #[test]
    fn ambiguous_p_defers() {
        assert_eq!(sniff(b"P"), Decision::NeedMore);
        assert_eq!(sniff(b"PRI"), Decision::NeedMore);
        assert_eq!(sniff(b"PRI * HTTP/2.0\r\n\r\nSM\r\n"), Decision::NeedMore);
    }

    #[test]
    fn post_is_not_preface() {
        assert_eq!(sniff(b"PO"), Decision::NeedMore);
        assert_eq!(sniff(b"POST /json/1 HTTP/1.1\r\n\r\n"), Decision::H1);
    }

    #[test]
    fn full_preface_is_grpc() {
        assert_eq!(sniff(H2_PREFACE), Decision::Grpc);
        let mut more = H2_PREFACE.to_vec();
        more.extend_from_slice(b"\x00\x00\x00\x04\x00");
        assert_eq!(sniff(&more), Decision::Grpc);
    }

    #[test]
    fn preface_split_defers_then_resolves() {
        assert_eq!(sniff(&H2_PREFACE[..10]), Decision::NeedMore);
        assert_eq!(sniff(&H2_PREFACE[..23]), Decision::NeedMore);
        assert_eq!(sniff(&H2_PREFACE[..24]), Decision::Grpc);
    }

    #[test]
    fn plain_h1_root() {
        assert_eq!(sniff(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"), Decision::H1);
        assert_eq!(sniff(b"GET /json/1 HTTP/1.1\r\n\r\n"), Decision::H1);
    }

    #[test]
    fn h1_request_line_incomplete_defers() {
        assert_eq!(sniff(b"GET /js"), Decision::NeedMore);
        assert_eq!(sniff(b"GET / HTTP/1.1\r"), Decision::NeedMore);
    }

    #[test]
    fn non_ws_path_decides_h1_immediately() {
        assert_eq!(sniff(b"GET /json/1 HTTP/1.1\r\n"), Decision::H1);
    }

    #[test]
    fn ws_path_with_upgrade_is_ws() {
        let req = b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
        assert_eq!(sniff(req), Decision::Ws);
    }

    #[test]
    fn ws_upgrade_case_insensitive() {
        let req = b"GET /ws HTTP/1.1\r\nupgrade:  WebSocket  \r\n\r\n";
        assert_eq!(sniff(req), Decision::Ws);
    }

    #[test]
    fn ws_path_no_upgrade_is_h1() {
        let req = b"GET /ws HTTP/1.1\r\nHost: x\r\n\r\n";
        assert_eq!(sniff(req), Decision::H1);
    }

    #[test]
    fn ws_path_headers_incomplete_defers() {
        assert_eq!(sniff(b"GET /ws HTTP/1.1\r\n"), Decision::NeedMore);
        assert_eq!(
            sniff(b"GET /ws HTTP/1.1\r\nUpgrade: websock"),
            Decision::NeedMore
        );
    }

    #[test]
    fn ws_with_query_is_ws() {
        let req = b"GET /ws?room=1 HTTP/1.1\r\nUpgrade: websocket\r\n\r\n";
        assert_eq!(sniff(req), Decision::Ws);
    }

    #[test]
    fn pipelined_first_root_is_h1() {
        let req = b"GET / HTTP/1.1\r\n\r\nGET /json/1 HTTP/1.1\r\n\r\n";
        assert_eq!(sniff(req), Decision::H1);
    }
}
