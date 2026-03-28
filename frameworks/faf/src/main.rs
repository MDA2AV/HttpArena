#![allow(dead_code)]

// HttpArena entry for FaF (Fast as Fuck)
// Architecture faithful to errantmind/faf:
//   - Raw epoll event loop (no async runtime, no framework)
//   - One thread per CPU core with SO_REUSEPORT
//   - Hand-rolled HTTP/1.1 parsing with pipelining support
//   - Direct syscalls for accept/recv/send via libc
//   - Zero-copy request processing
//
// Extended beyond faf's callback API to support POST body reading
// required by HttpArena's baseline test profile.

use std::net::SocketAddr;
use std::os::unix::io::AsRawFd;

// ── Constants ───────────────────────────────────────────────────────────

const MAX_CONN: usize = 4096;
const REQ_BUF_SIZE: usize = 8192;
const RES_BUF_SIZE: usize = 65536;
const MAX_EVENTS: i32 = 512;

const RESP_PREFIX: &[u8] = b"HTTP/1.1 200 OK\r\nServer: faf\r\nContent-Type: text/plain\r\nContent-Length: ";
const RESP_OK: &[u8] = b"HTTP/1.1 200 OK\r\nServer: faf\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok";
const RESP_404: &[u8] = b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";

// ── HTTP parsing ────────────────────────────────────────────────────────

/// Find \r\n\r\n in buffer. Returns offset past it, or 0 if not found.
#[inline(always)]
fn find_headers_end(buf: &[u8]) -> usize {
    let len = buf.len();
    if len < 4 { return 0; }
    for i in 0..len - 3 {
        if buf[i] == b'\r' && buf[i + 1] == b'\n' && buf[i + 2] == b'\r' && buf[i + 3] == b'\n' {
            return i + 4;
        }
    }
    0
}

/// Extract Content-Length from headers (case-insensitive). Returns (content_length, is_chunked).
#[inline(always)]
fn parse_transfer_info(buf: &[u8], headers_end: usize) -> (usize, bool) {
    let hay = &buf[..headers_end];
    let mut cl = 0usize;
    for i in 0..hay.len().saturating_sub(4) {
        if hay[i] != b'\r' || hay[i + 1] != b'\n' { continue; }

        // Check Content-Length
        if i + 18 < headers_end && is_content_length(&hay[i + 2..]) {
            let start = i + 18;
            let mut j = start;
            while j < headers_end && hay[j] >= b'0' && hay[j] <= b'9' {
                cl = cl * 10 + (hay[j] - b'0') as usize;
                j += 1;
            }
        }
    }

    let chunked = has_chunked_encoding(hay, headers_end);
    (cl, chunked)
}

/// Check for "Transfer-Encoding: chunked" header (case-insensitive key)
#[inline(always)]
fn has_chunked_encoding(hay: &[u8], headers_end: usize) -> bool {
    // Look for "\r\nTransfer-Encoding:" pattern
    let needle_lower = b"transfer-encoding:";
    let nlen = needle_lower.len(); // 18

    for i in 0..headers_end.saturating_sub(nlen + 2) {
        if hay[i] != b'\r' || hay[i + 1] != b'\n' { continue; }
        let start = i + 2;
        if start + nlen > headers_end { continue; }

        // Case-insensitive match of "transfer-encoding:"
        let mut matched = true;
        for j in 0..nlen {
            let a = hay[start + j].to_ascii_lowercase();
            if a != needle_lower[j] { matched = false; break; }
        }
        if !matched { continue; }

        // Check value contains "chunked"
        let val_start = start + nlen;
        let line_end = hay[val_start..headers_end].iter()
            .position(|&b| b == b'\r').map(|p| val_start + p).unwrap_or(headers_end);
        let val = &hay[val_start..line_end];
        // Simple check: value contains "chunked"
        if val.windows(7).any(|w| w.eq_ignore_ascii_case(b"chunked")) {
            return true;
        }
    }
    false
}

/// Parse chunked transfer encoding body. Returns (decoded_data, total_bytes_consumed).
/// For our use case, we just need to extract the body content.
#[inline(always)]
fn decode_chunked(buf: &[u8]) -> (Vec<u8>, usize) {
    let mut result = Vec::new();
    let mut pos = 0;
    let len = buf.len();

    loop {
        if pos >= len { return (result, pos); }

        // Parse chunk size (hex)
        let mut chunk_size: usize = 0;
        let mut has_size = false;
        while pos < len {
            let b = buf[pos];
            if b >= b'0' && b <= b'9' {
                chunk_size = chunk_size * 16 + (b - b'0') as usize;
                has_size = true;
            } else if b >= b'a' && b <= b'f' {
                chunk_size = chunk_size * 16 + (b - b'a' + 10) as usize;
                has_size = true;
            } else if b >= b'A' && b <= b'F' {
                chunk_size = chunk_size * 16 + (b - b'A' + 10) as usize;
                has_size = true;
            } else {
                break;
            }
            pos += 1;
        }

        if !has_size { return (result, pos); }

        // Skip \r\n after chunk size
        if pos + 1 < len && buf[pos] == b'\r' && buf[pos + 1] == b'\n' {
            pos += 2;
        }

        // Terminating chunk (size 0)
        if chunk_size == 0 {
            // Skip trailing \r\n
            if pos + 1 < len && buf[pos] == b'\r' && buf[pos + 1] == b'\n' {
                pos += 2;
            }
            return (result, pos);
        }

        // Read chunk data
        if pos + chunk_size > len { return (result, pos); }
        result.extend_from_slice(&buf[pos..pos + chunk_size]);
        pos += chunk_size;

        // Skip \r\n after chunk data
        if pos + 1 < len && buf[pos] == b'\r' && buf[pos + 1] == b'\n' {
            pos += 2;
        }
    }
}

#[inline(always)]
fn is_content_length(b: &[u8]) -> bool {
    b.len() >= 16
        && (b[0] == b'C' || b[0] == b'c')
        && (b[1] == b'o' || b[1] == b'O')
        && (b[2] == b'n' || b[2] == b'N')
        && (b[3] == b't' || b[3] == b'T')
        && (b[4] == b'e' || b[4] == b'E')
        && (b[5] == b'n' || b[5] == b'N')
        && (b[6] == b't' || b[6] == b'T')
        && b[7] == b'-'
        && (b[8] == b'L' || b[8] == b'l')
        && (b[9] == b'e' || b[9] == b'E')
        && (b[10] == b'n' || b[10] == b'N')
        && (b[11] == b'g' || b[11] == b'G')
        && (b[12] == b't' || b[12] == b'T')
        && (b[13] == b'h' || b[13] == b'H')
        && b[14] == b':'
        && b[15] == b' '
}

/// Sum all query parameter numeric values: ?a=1&b=2 → 3
#[inline(always)]
fn parse_query_sum(path: &[u8]) -> i64 {
    let mut sum: i64 = 0;
    let qmark = match path.iter().position(|&b| b == b'?') {
        Some(p) => p + 1,
        None => return 0,
    };
    let qs = &path[qmark..];
    for pair in qs.split(|&b| b == b'&') {
        if let Some(eq) = pair.iter().position(|&b| b == b'=') {
            let val_bytes = &pair[eq + 1..];
            if let Ok(s) = std::str::from_utf8(val_bytes) {
                if let Ok(n) = s.parse::<i64>() {
                    sum += n;
                }
            }
        }
    }
    sum
}

/// Parse body as trimmed integer.
#[inline(always)]
fn parse_body_i64(body: &[u8]) -> i64 {
    if let Ok(s) = std::str::from_utf8(body) {
        s.trim().parse::<i64>().unwrap_or(0)
    } else {
        0
    }
}

/// Write i64 as ASCII decimal, return bytes written.
#[inline(always)]
fn write_i64(buf: &mut [u8], val: i64) -> usize {
    // Fast path for small positive numbers (most common case)
    let s = itoa_fast(val);
    let bytes = s.as_bytes();
    buf[..bytes.len()].copy_from_slice(bytes);
    bytes.len()
}

// Inline itoa using stack buffer
fn itoa_fast(val: i64) -> String {
    // Use stack-allocated formatting for speed
    use std::fmt::Write;
    let mut s = String::with_capacity(20);
    let _ = write!(s, "{}", val);
    s
}

/// Build "200 OK text/plain" response into buf. Returns total bytes.
#[inline(always)]
fn build_response(buf: &mut [u8], body: &[u8]) -> usize {
    let mut off = 0;
    buf[off..off + RESP_PREFIX.len()].copy_from_slice(RESP_PREFIX);
    off += RESP_PREFIX.len();
    off += write_i64(&mut buf[off..], body.len() as i64);
    buf[off..off + 4].copy_from_slice(b"\r\n\r\n");
    off += 4;
    buf[off..off + body.len()].copy_from_slice(body);
    off + body.len()
}

/// Check if path matches a route (exact or followed by '?').
#[inline(always)]
fn path_matches(path: &[u8], route: &[u8]) -> bool {
    path.len() >= route.len()
        && &path[..route.len()] == route
        && (path.len() == route.len() || path[route.len()] == b'?')
}

// ── Epoll event loop ────────────────────────────────────────────────────

fn worker(listener_fd: i32) {
    unsafe {
        let epfd = libc::epoll_create1(0);
        assert!(epfd >= 0, "epoll_create1 failed");

        let mut ev = libc::epoll_event { events: libc::EPOLLIN as u32, u64: listener_fd as u64 };
        libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, listener_fd, &mut ev);

        let mut reqbufs: Vec<Vec<u8>> = (0..MAX_CONN).map(|_| vec![0u8; REQ_BUF_SIZE]).collect();
        let mut filled = vec![0usize; MAX_CONN];
        let mut resbuf = vec![0u8; RES_BUF_SIZE];
        let mut events: Vec<libc::epoll_event> = vec![std::mem::zeroed(); MAX_EVENTS as usize];
        let mut timeout: i32 = -1;

        loop {
            let n = libc::epoll_wait(epfd, events.as_mut_ptr(), MAX_EVENTS, timeout);

            if n <= 0 { timeout = -1; continue; }
            timeout = 0; // Non-blocking on hot path (faf pattern)

            for idx in 0..n as usize {
                let fd = events[idx].u64 as i32;

                if fd == listener_fd {
                    // Accept loop — drain all pending connections (faf pattern)
                    loop {
                        let cfd = libc::accept4(fd, std::ptr::null_mut(),
                            std::ptr::null_mut(), libc::SOCK_NONBLOCK);
                        if cfd < 0 { break; }
                        if (cfd as usize) < MAX_CONN {
                            let one: i32 = 1;
                            libc::setsockopt(cfd, libc::IPPROTO_TCP, libc::TCP_NODELAY,
                                &one as *const _ as *const libc::c_void, 4);
                            filled[cfd as usize] = 0;
                            let mut cev = libc::epoll_event {
                                events: libc::EPOLLIN as u32,
                                u64: cfd as u64,
                            };
                            libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, cfd, &mut cev);
                        } else {
                            libc::close(cfd);
                        }
                    }
                    continue;
                }

                let fi = fd as usize;
                if fi >= MAX_CONN {
                    libc::epoll_ctl(epfd, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut());
                    libc::close(fd);
                    continue;
                }

                let cur = filled[fi];
                let ptr = reqbufs[fi].as_mut_ptr().add(cur);
                let read = libc::recv(fd, ptr as *mut libc::c_void, REQ_BUF_SIZE - cur, 0);

                if read <= 0 {
                    if read < 0 {
                        let err = *libc::__errno_location();
                        if err == libc::EAGAIN || err == libc::EINTR { continue; }
                    }
                    libc::epoll_ctl(epfd, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut());
                    libc::close(fd);
                    filled[fi] = 0;
                    continue;
                }

                let total = cur + read as usize;
                let mut consumed = 0usize;
                let mut res_off = 0usize;

                // Pipelined request processing loop (core faf pattern)
                while consumed < total {
                    let rem = &reqbufs[fi][consumed..total];
                    if rem.len() < 16 { break; }

                    let hdr_end = find_headers_end(rem);
                    if hdr_end == 0 { break; }

                    // Parse request line
                    let sp1 = match rem.iter().position(|&b| b == b' ') {
                        Some(p) => p,
                        None => break,
                    };
                    let method = &rem[..sp1];

                    let mut ps = sp1 + 1;
                    while ps < rem.len() && rem[ps] == b' ' { ps += 1; }
                    let pe = match rem[ps..].iter().position(|&b| b == b' ' || b == b'\r') {
                        Some(p) => ps + p,
                        None => break,
                    };
                    let path = &rem[ps..pe];

                    let is_post = method == b"POST";
                    let (cl, chunked) = if is_post {
                        parse_transfer_info(rem, hdr_end)
                    } else {
                        (0, false)
                    };

                    // Determine body and total request length
                    let (body_data, full_len) = if is_post && chunked {
                        let (decoded, chunk_bytes) = decode_chunked(&rem[hdr_end..]);
                        (Some(decoded), hdr_end + chunk_bytes)
                    } else {
                        let full = hdr_end + cl;
                        if full > rem.len() { break; }
                        (None, full)
                    };

                    if full_len > rem.len() { break; }

                    let rlen = if path_matches(path, b"/pipeline") {
                        resbuf[res_off..res_off + RESP_OK.len()].copy_from_slice(RESP_OK);
                        RESP_OK.len()
                    } else if path_matches(path, b"/baseline11") {
                        let mut sum = parse_query_sum(path);
                        if is_post {
                            if let Some(ref data) = body_data {
                                if !data.is_empty() { sum += parse_body_i64(data); }
                            } else if cl > 0 {
                                sum += parse_body_i64(&rem[hdr_end..hdr_end + cl]);
                            }
                        }
                        let body = itoa_fast(sum);
                        build_response(&mut resbuf[res_off..], body.as_bytes())
                    } else {
                        resbuf[res_off..res_off + RESP_404.len()].copy_from_slice(RESP_404);
                        RESP_404.len()
                    };

                    res_off += rlen;
                    consumed += full_len;
                }

                // Flush all batched responses (faf pattern: single write for pipelined requests)
                if res_off > 0 {
                    let w = libc::send(fd, resbuf.as_ptr() as *const libc::c_void,
                        res_off, 0);
                    if w < 0 {
                        let err = *libc::__errno_location();
                        if err != libc::EAGAIN && err != libc::EINTR {
                            libc::epoll_ctl(epfd, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut());
                            libc::close(fd);
                            filled[fi] = 0;
                            continue;
                        }
                    }
                }

                // Keep unconsumed bytes for next read (partial request handling)
                if consumed > 0 && consumed < total {
                    let left = total - consumed;
                    reqbufs[fi].copy_within(consumed..total, 0);
                    filled[fi] = left;
                } else if consumed >= total {
                    filled[fi] = 0;
                } else {
                    filled[fi] = total;
                }
            }
        }
    }
}

// ── Socket setup ────────────────────────────────────────────────────────

fn create_listener() -> i32 {
    use socket2::{Domain, Socket, Type};
    let socket = Socket::new(Domain::IPV4, Type::STREAM, None).expect("socket");
    socket.set_reuse_address(true).expect("reuseaddr");
    socket.set_reuse_port(true).expect("reuseport");
    socket.set_nodelay(true).expect("nodelay");
    socket.set_nonblocking(true).expect("nonblock");
    let addr: SocketAddr = "0.0.0.0:8080".parse().unwrap();
    socket.bind(&addr.into()).expect("bind");
    socket.listen(4096).expect("listen");
    let fd = socket.as_raw_fd();
    std::mem::forget(socket); // Don't close on drop — worker owns the fd
    fd
}

// ── Main ────────────────────────────────────────────────────────────────

fn main() {
    // Elevate process priority (faf pattern)
    unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, -19); }

    let ncpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);

    // One thread per core, each with its own listener socket via SO_REUSEPORT (faf pattern)
    for _ in 1..ncpus {
        std::thread::Builder::new()
            .stack_size(8 * 1024 * 1024)
            .spawn(|| {
                let fd = create_listener();
                worker(fd);
            })
            .expect("spawn thread");
    }

    let fd = create_listener();
    worker(fd);
}
