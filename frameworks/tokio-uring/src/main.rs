//! tokio-uring — a minimal HTTP/1.1 server on tokio-uring for the H1-isolated
//! profiles (baseline, pipelined, limited-conn). No HTTP framework: the request
//! parser (request line, headers, Content-Length + chunked bodies, keep-alive,
//! pipelining, fragmented reads) is hand-rolled on tokio-uring's owned-buffer
//! TcpStream.
//!
//! Serving model: one tokio_uring::start per core, each with its own
//! SO_REUSEPORT listener (socket2 + from_std). Listens on 0.0.0.0:8080
//! (PORT overrides for testing).
//!
//! Endpoints:
//!   GET/POST /baseline11?a=&b=  -> text/plain "a + b (+ body)"
//!   GET      /pipeline          -> text/plain "ok"

use socket2::{Domain, Protocol, Socket, Type};
use std::net::SocketAddr;
use tokio_uring::net::{TcpListener, TcpStream};

const READ_SIZE: usize = 16 * 1024;
const MAX_BUF: usize = 1 << 20;

fn main() {
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);
    let mut handles = Vec::with_capacity(threads);
    for _ in 0..threads {
        handles.push(std::thread::spawn(|| tokio_uring::start(serve())));
    }
    for h in handles {
        let _ = h.join();
    }
}

async fn serve() {
    let listener = bind_reuseport();
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio_uring::spawn(handle(stream));
            }
            Err(_) => continue,
        }
    }
}

fn bind_reuseport() -> TcpListener {
    let port = std::env::var("PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8080u16);
    let addr: SocketAddr = format!("0.0.0.0:{port}").parse().unwrap();
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).unwrap();
    socket.set_reuse_address(true).unwrap();
    socket.set_reuse_port(true).unwrap();
    socket.bind(&addr.into()).unwrap();
    socket.listen(1024).unwrap();
    TcpListener::from_std(socket.into())
}

async fn handle(stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let mut buf: Vec<u8> = Vec::with_capacity(READ_SIZE);
    let mut out: Vec<u8> = Vec::with_capacity(READ_SIZE);
    let mut rbuf: Vec<u8> = vec![0u8; READ_SIZE];

    loop {
        let mut pos = 0;
        let mut keep = true;
        loop {
            match process(&buf[pos..], &mut out) {
                Outcome::Incomplete => break,
                Outcome::Complete { consumed, keep_alive } => {
                    pos += consumed;
                    if !keep_alive {
                        keep = false;
                        break;
                    }
                }
            }
        }
        if pos > 0 {
            buf.drain(..pos);
        }
        if !out.is_empty() {
            let (res, mut o) = stream.write_all(out).await;
            o.clear();
            out = o;
            if res.is_err() {
                return;
            }
        }
        if !keep || buf.len() > MAX_BUF {
            return;
        }
        let (res, b) = stream.read(rbuf).await;
        rbuf = b;
        let n = match res {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        buf.extend_from_slice(&rbuf[..n]);
    }
}

// ── Hand-rolled HTTP/1.1 ─────────────────────────────────────────────────────

enum Outcome {
    Incomplete,
    Complete { consumed: usize, keep_alive: bool },
}

/// Parse one request from buf; append its response to out. Returns Incomplete if
/// the request isn't fully buffered yet.
fn process(buf: &[u8], out: &mut Vec<u8>) -> Outcome {
    let he = match find(buf, b"\r\n\r\n") {
        Some(h) => h,
        None => return Outcome::Incomplete,
    };

    let mut lines = lines_crlf(&buf[..he]);
    let req_line = lines.next().unwrap_or(b"");
    let mut rl = req_line.split(|&c| c == b' ');
    let _method = rl.next().unwrap_or(b"");
    let target = rl.next().unwrap_or(b"");

    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    let mut close = false;
    for line in lines {
        if let Some(c) = find(line, b":") {
            let name = &line[..c];
            let val = trim(&line[c + 1..]);
            if ci_eq(name, b"content-length") {
                content_length = parse_usize(val);
            } else if ci_eq(name, b"transfer-encoding") && ci_contains(val, b"chunked") {
                chunked = true;
            } else if ci_eq(name, b"connection") && ci_eq(val, b"close") {
                close = true;
            }
        }
    }

    let body_start = he + 4;
    let (body_int, consumed) = if chunked {
        match decode_chunked(&buf[body_start..]) {
            Some((body, used)) => (parse_i64(&body), body_start + used),
            None => return Outcome::Incomplete,
        }
    } else if let Some(cl) = content_length {
        if buf.len() < body_start + cl {
            return Outcome::Incomplete;
        }
        (parse_i64(&buf[body_start..body_start + cl]), body_start + cl)
    } else {
        (0, body_start)
    };

    respond(out, target, body_int);
    Outcome::Complete { consumed, keep_alive: !close }
}

fn respond(out: &mut Vec<u8>, target: &[u8], body_int: i64) {
    let q = find(target, b"?");
    let path = match q {
        Some(i) => &target[..i],
        None => target,
    };
    if path == b"/pipeline" {
        write_resp(out, b"ok");
    } else {
        let query = match q {
            Some(i) => &target[i + 1..],
            None => &[][..],
        };
        let (a, b) = parse_ab(query);
        let s = (a + b + body_int).to_string();
        write_resp(out, s.as_bytes());
    }
}

fn write_resp(out: &mut Vec<u8>, body: &[u8]) {
    out.extend_from_slice(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ");
    out.extend_from_slice(body.len().to_string().as_bytes());
    out.extend_from_slice(b"\r\n\r\n");
    out.extend_from_slice(body);
}

fn parse_ab(query: &[u8]) -> (i64, i64) {
    let (mut a, mut b) = (0i64, 0i64);
    for kv in query.split(|&c| c == b'&') {
        if let Some(eq) = find(kv, b"=") {
            let (k, v) = (&kv[..eq], &kv[eq + 1..]);
            if k == b"a" {
                a = parse_i64(v);
            } else if k == b"b" {
                b = parse_i64(v);
            }
        }
    }
    (a, b)
}

/// Decode a chunked body. Returns (decoded_bytes, bytes_consumed) or None if the
/// terminating 0-chunk isn't fully buffered yet.
fn decode_chunked(buf: &[u8]) -> Option<(Vec<u8>, usize)> {
    let mut body = Vec::new();
    let mut pos = 0;
    loop {
        let nl = find(&buf[pos..], b"\r\n")?;
        let size = parse_hex(&buf[pos..pos + nl])?;
        pos += nl + 2;
        if size == 0 {
            let end = find(&buf[pos..], b"\r\n")?; // final CRLF (no trailers)
            return Some((body, pos + end + 2));
        }
        if buf.len() < pos + size + 2 {
            return None;
        }
        body.extend_from_slice(&buf[pos..pos + size]);
        pos += size;
        if &buf[pos..pos + 2] != b"\r\n" {
            return None;
        }
        pos += 2;
    }
}

// ── byte helpers ─────────────────────────────────────────────────────────────

fn find(h: &[u8], n: &[u8]) -> Option<usize> {
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    h.windows(n.len()).position(|w| w == n)
}

fn lines_crlf(b: &[u8]) -> impl Iterator<Item = &[u8]> {
    b.split(|&c| c == b'\n').map(|l| {
        if l.last() == Some(&b'\r') {
            &l[..l.len() - 1]
        } else {
            l
        }
    })
}

fn trim(mut b: &[u8]) -> &[u8] {
    while matches!(b.first(), Some(b' ') | Some(b'\t')) {
        b = &b[1..];
    }
    while matches!(b.last(), Some(b' ') | Some(b'\t')) {
        b = &b[..b.len() - 1];
    }
    b
}

fn ci_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.eq_ignore_ascii_case(y))
}

fn ci_contains(h: &[u8], n: &[u8]) -> bool {
    !n.is_empty() && h.len() >= n.len() && h.windows(n.len()).any(|w| ci_eq(w, n))
}

fn parse_i64(b: &[u8]) -> i64 {
    let b = trim(b);
    let (neg, b) = match b.first() {
        Some(b'-') => (true, &b[1..]),
        _ => (false, b),
    };
    let mut n = 0i64;
    for &c in b {
        if c.is_ascii_digit() {
            n = n * 10 + (c - b'0') as i64;
        } else {
            break;
        }
    }
    if neg {
        -n
    } else {
        n
    }
}

fn parse_usize(b: &[u8]) -> Option<usize> {
    let b = trim(b);
    if b.is_empty() || !b.iter().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let mut n = 0usize;
    for &c in b {
        n = n.checked_mul(10)?.checked_add((c - b'0') as usize)?;
    }
    Some(n)
}

fn parse_hex(b: &[u8]) -> Option<usize> {
    let mut n = 0usize;
    let mut any = false;
    for &c in b {
        let d = match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            b'A'..=b'F' => c - b'A' + 10,
            b';' | b' ' => break, // chunk extensions / padding
            _ => return if any { Some(n) } else { None },
        };
        n = n.checked_mul(16)?.checked_add(d as usize)?;
        any = true;
    }
    if any {
        Some(n)
    } else {
        None
    }
}
