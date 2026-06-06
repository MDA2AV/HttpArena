//! tokio-uring-ws — a hand-rolled WebSocket echo server on tokio-uring.
//!
//! tokio-uring is an io_uring-backed Rust runtime with a completion-based,
//! owned-buffer API (`read`/`write_all` take a buffer by value and hand it
//! back). It runs one runtime per thread, so the serving model here is one
//! `tokio_uring::start` per core, each with its own `SO_REUSEPORT` listener
//! (kernel-sharded accept, no cross-core work-stealing).
//!
//! No WebSocket library: the RFC 6455 handshake (with from-scratch SHA-1 +
//! base64), the frame parser, masking, and the echo path are all written here.
//! Listens on 0.0.0.0:8080, WebSocket on /ws.

use socket2::{Domain, Protocol, Socket, Type};
use std::net::SocketAddr;
use tokio_uring::net::{TcpListener, TcpStream};

const ADDR: &str = "0.0.0.0:8080";
const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_FRAME: usize = 16 << 20;
const READ_SIZE: usize = 16 * 1024;

const RESP_400: &[u8] = b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
const RESP_404: &[u8] = b"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";

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

/// One sharded tokio-uring runtime + accept loop per core.
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

/// A SO_REUSEPORT listener handed to tokio-uring via from_std.
fn bind_reuseport() -> TcpListener {
    let addr: SocketAddr = ADDR.parse().expect("valid addr");
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).expect("socket");
    socket.set_reuse_address(true).expect("reuseaddr");
    socket.set_reuse_port(true).expect("reuseport");
    socket.bind(&addr.into()).expect("bind");
    socket.listen(1024).expect("listen");
    TcpListener::from_std(socket.into())
}

async fn handle(stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let mut carry: Vec<u8> = Vec::with_capacity(READ_SIZE);
    let mut rbuf: Vec<u8> = vec![0u8; READ_SIZE];
    let mut out: Vec<u8> = Vec::with_capacity(READ_SIZE);

    // ── Handshake ────────────────────────────────────────────────────────────
    loop {
        if let Some(he) = find_header_end(&carry) {
            let ok = do_handshake(&mut carry, he, &mut out);
            if !out.is_empty() {
                let (res, mut o) = stream.write_all(out).await;
                o.clear();
                out = o;
                if res.is_err() {
                    return;
                }
            }
            if !ok {
                return; // 4xx already sent
            }
            break;
        }
        if carry.len() > 16 * 1024 {
            return; // headers too large
        }
        let (res, b) = stream.read(rbuf).await;
        rbuf = b;
        let n = match res {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        carry.extend_from_slice(&rbuf[..n]);
    }

    // ── Echo loop ────────────────────────────────────────────────────────────
    loop {
        let (consumed, stop) = ws_drain(&mut carry, &mut out);
        if consumed > 0 {
            carry.drain(..consumed);
        }
        if !out.is_empty() {
            let (res, mut o) = stream.write_all(out).await;
            o.clear();
            out = o;
            if res.is_err() {
                return;
            }
        }
        if stop {
            return;
        }
        let (res, b) = stream.read(rbuf).await;
        rbuf = b;
        let n = match res {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        carry.extend_from_slice(&rbuf[..n]);
    }
}

// ── Handshake ────────────────────────────────────────────────────────────────

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

/// Parse the request in carry[0..he); queue 101 (and drop the request bytes,
/// keeping any trailing frame bytes) or a 4xx. Returns true on upgrade.
fn do_handshake(carry: &mut Vec<u8>, he: usize, out: &mut Vec<u8>) -> bool {
    let (path_is_ws, key, upgrade) = {
        let head = match std::str::from_utf8(&carry[..he]) {
            Ok(t) => t,
            Err(_) => return false,
        };
        let mut lines = head.split("\r\n");
        let req = lines.next().unwrap_or("");
        let path_is_ws = req.split(' ').nth(1) == Some("/ws");
        let mut key: Option<String> = None;
        let mut upgrade = false;
        for line in lines {
            if let Some((n, v)) = line.split_once(':') {
                let (n, v) = (n.trim(), v.trim());
                if n.eq_ignore_ascii_case("sec-websocket-key") {
                    key = Some(v.to_string());
                } else if n.eq_ignore_ascii_case("upgrade") && v.eq_ignore_ascii_case("websocket") {
                    upgrade = true;
                }
            }
        }
        (path_is_ws, key, upgrade)
    };

    if !path_is_ws {
        out.extend_from_slice(RESP_404);
        return false;
    }
    let key = match (key, upgrade) {
        (Some(k), true) => k,
        _ => {
            out.extend_from_slice(RESP_400);
            return false;
        }
    };

    let accept = ws_accept(&key);
    carry.drain(..he + 4);
    out.extend_from_slice(
        format!(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\
             Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        )
        .as_bytes(),
    );
    true
}

fn ws_accept(key: &str) -> String {
    let mut input = String::with_capacity(key.len() + WS_GUID.len());
    input.push_str(key);
    input.push_str(WS_GUID);
    base64_encode(&sha1(input.as_bytes()))
}

// ── Frame codec ──────────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
struct Frame {
    fin: bool,
    opcode: u8,
    mask: Option<[u8; 4]>,
    payload_off: usize,
    payload_len: usize,
    total: usize,
}

enum Parse {
    Frame(Frame),
    Incomplete,
    Error,
}

/// Drain complete frames from buf, unmasking in place and appending unmasked
/// echoes to `out`. Returns (bytes_consumed, should_close).
fn ws_drain(buf: &mut [u8], out: &mut Vec<u8>) -> (usize, bool) {
    let mut off = 0;
    loop {
        let f = match parse_frame(&buf[off..]) {
            Parse::Frame(f) => f,
            Parse::Incomplete => break,
            Parse::Error => return (off, true),
        };
        let start = off + f.payload_off;
        let end = start + f.payload_len;
        if let Some(mask) = f.mask {
            for i in 0..f.payload_len {
                buf[start + i] ^= mask[i & 3];
            }
        }
        match f.opcode {
            0x0 | 0x1 | 0x2 => {
                push_header(out, f.fin, f.opcode, f.payload_len);
                out.extend_from_slice(&buf[start..end]);
            }
            0x9 => {
                push_header(out, true, 0xA, f.payload_len);
                out.extend_from_slice(&buf[start..end]);
            }
            0x8 => {
                push_header(out, true, 0x8, f.payload_len);
                out.extend_from_slice(&buf[start..end]);
                return (off + f.total, true);
            }
            _ => {}
        }
        off += f.total;
    }
    (off, false)
}

fn parse_frame(buf: &[u8]) -> Parse {
    if buf.len() < 2 {
        return Parse::Incomplete;
    }
    let b0 = buf[0];
    let b1 = buf[1];
    let masked = b1 & 0x80 != 0;
    let len7 = (b1 & 0x7F) as usize;
    let (payload_len, mut off) = if len7 < 126 {
        (len7, 2usize)
    } else if len7 == 126 {
        if buf.len() < 4 {
            return Parse::Incomplete;
        }
        (u16::from_be_bytes([buf[2], buf[3]]) as usize, 4)
    } else {
        if buf.len() < 10 {
            return Parse::Incomplete;
        }
        let l = u64::from_be_bytes([
            buf[2], buf[3], buf[4], buf[5], buf[6], buf[7], buf[8], buf[9],
        ]);
        if l > MAX_FRAME as u64 {
            return Parse::Error;
        }
        (l as usize, 10)
    };
    if payload_len > MAX_FRAME {
        return Parse::Error;
    }
    let mask = if masked {
        if buf.len() < off + 4 {
            return Parse::Incomplete;
        }
        let m = [buf[off], buf[off + 1], buf[off + 2], buf[off + 3]];
        off += 4;
        Some(m)
    } else {
        None
    };
    if buf.len() < off + payload_len {
        return Parse::Incomplete;
    }
    Parse::Frame(Frame {
        fin: b0 & 0x80 != 0,
        opcode: b0 & 0x0F,
        mask,
        payload_off: off,
        payload_len,
        total: off + payload_len,
    })
}

fn push_header(out: &mut Vec<u8>, fin: bool, opcode: u8, len: usize) {
    out.push(if fin { 0x80 } else { 0 } | (opcode & 0x0F));
    if len < 126 {
        out.push(len as u8);
    } else if len <= u16::MAX as usize {
        out.push(126);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(127);
        out.extend_from_slice(&(len as u64).to_be_bytes());
    }
}

// ── Hand-rolled SHA-1 + base64 (handshake only) ──────────────────────────────

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0];
    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    let mut w = [0u32; 80];
    for chunk in msg.chunks_exact(64) {
        for (i, word) in chunk.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let tmp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = tmp;
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }

    let mut out = [0u8; 20];
    for (i, word) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

fn base64_encode(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { T[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
    }
    out
}
