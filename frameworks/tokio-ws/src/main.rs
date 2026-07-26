//! tokio-ws — a hand-rolled WebSocket echo server on raw tokio.
//!
//! No WebSocket library: the RFC 6455 handshake (including a from-scratch SHA-1
//! and base64), the frame parser, masking, and the echo write path are all
//! implemented here directly on a `tokio::net::TcpStream`. The serving model is
//! one `current_thread` runtime per core with `SO_REUSEPORT` sharding, matching
//! the other low-level "engine" entries.
//!
//! Endpoint: `GET /ws` upgrade, then echo every Text/Binary frame back verbatim
//! (unmasked, as a server frame). Listens on `0.0.0.0:8080`.

use socket2::{Domain, Protocol, Socket, Type};
use std::net::SocketAddr;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const ADDR: &str = "0.0.0.0:8080";
const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_FRAME: u64 = 16 << 20; // 16 MiB — DoS guard on the declared length
const READ_CHUNK: usize = 16 * 1024;

fn main() {
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);

    let mut handles = Vec::with_capacity(threads);
    for _ in 0..threads {
        handles.push(std::thread::spawn(|| {
            tokio::runtime::Builder::new_current_thread()
                .enable_io()
                .build()
                .expect("build runtime")
                .block_on(serve());
        }));
    }
    for h in handles {
        let _ = h.join();
    }
}

/// One sharded listener + accept loop per core.
async fn serve() {
    let listener = bind_reuseport().expect("bind 0.0.0.0:8080");
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(handle(stream));
            }
            // Transient accept errors (EMFILE etc.) — keep the loop alive.
            Err(_) => continue,
        }
    }
}

/// A reusable, SO_REUSEPORT listener so every core gets its own accept queue.
fn bind_reuseport() -> std::io::Result<TcpListener> {
    let addr: SocketAddr = ADDR.parse().expect("valid addr");
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_reuse_address(true)?;
    socket.set_reuse_port(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr.into())?;
    socket.listen(1024)?;
    TcpListener::from_std(socket.into())
}

async fn handle(mut stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let mut buf: Vec<u8> = Vec::with_capacity(8192);
    if !handshake(&mut stream, &mut buf).await {
        return;
    }
    // `buf` carries any bytes the client pipelined after the handshake.
    let _ = echo_loop(&mut stream, buf).await;
}

// ── Handshake ────────────────────────────────────────────────────────────────

/// Read request headers, validate the upgrade, and reply 101 (or 4xx). On
/// success, `buf` is left holding only the post-handshake byte stream.
async fn handshake(stream: &mut TcpStream, buf: &mut Vec<u8>) -> bool {
    let mut tmp = [0u8; 4096];
    let hdr_end = loop {
        if let Some(p) = find_header_end(buf) {
            break p;
        }
        if buf.len() > 16 * 1024 {
            return false; // headers too large
        }
        match stream.read(&mut tmp).await {
            Ok(0) => return false,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(_) => return false,
        }
    };

    let head = match std::str::from_utf8(&buf[..hdr_end]) {
        Ok(t) => t,
        Err(_) => return false,
    };

    let mut lines = head.split("\r\n");
    let request_line = lines.next().unwrap_or("");
    let path = request_line.split(' ').nth(1).unwrap_or("");

    let mut key: Option<&str> = None;
    let mut upgrade_ws = false;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim();
            let value = value.trim();
            if name.eq_ignore_ascii_case("sec-websocket-key") {
                key = Some(value);
            } else if name.eq_ignore_ascii_case("upgrade")
                && value.eq_ignore_ascii_case("websocket")
            {
                upgrade_ws = true;
            }
        }
    }

    if path != "/ws" {
        let _ = stream
            .write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            .await;
        return false;
    }

    let key = match (key, upgrade_ws) {
        (Some(k), true) => k,
        // Non-upgrade GET /ws (or missing key) must be rejected, not upgraded.
        _ => {
            let _ = stream
                .write_all(
                    b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
                )
                .await;
            return false;
        }
    };

    let accept = ws_accept(key);
    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    if stream.write_all(resp.as_bytes()).await.is_err() {
        return false;
    }

    buf.drain(..hdr_end + 4); // drop the consumed request, keep any trailing frames
    true
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

fn ws_accept(key: &str) -> String {
    let mut input = String::with_capacity(key.len() + WS_GUID.len());
    input.push_str(key);
    input.push_str(WS_GUID);
    base64_encode(&sha1(input.as_bytes()))
}

// ── Frame echo loop ──────────────────────────────────────────────────────────

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

async fn echo_loop(stream: &mut TcpStream, mut buf: Vec<u8>) -> std::io::Result<()> {
    let mut pos = 0usize;
    let mut out: Vec<u8> = Vec::with_capacity(8192);
    let mut tmp = [0u8; READ_CHUNK];

    loop {
        // Drain every complete frame currently buffered, batching the echoes.
        loop {
            let f = match parse_frame(&buf[pos..]) {
                Parse::Frame(f) => f,
                Parse::Incomplete => break,
                Parse::Error => return Ok(()), // malformed/oversized → drop the conn
            };

            let start = pos + f.payload_off;
            let end = start + f.payload_len;
            if let Some(mask) = f.mask {
                for i in 0..f.payload_len {
                    buf[start + i] ^= mask[i & 3];
                }
            }

            match f.opcode {
                // Continuation / Text / Binary → echo verbatim, unmasked.
                0x0 | 0x1 | 0x2 => {
                    push_header(&mut out, f.fin, f.opcode, f.payload_len);
                    out.extend_from_slice(&buf[start..end]);
                }
                // Ping → Pong with the same payload.
                0x9 => {
                    push_header(&mut out, true, 0xA, f.payload_len);
                    out.extend_from_slice(&buf[start..end]);
                }
                // Close → echo the close frame and finish.
                0x8 => {
                    push_header(&mut out, true, 0x8, f.payload_len);
                    out.extend_from_slice(&buf[start..end]);
                    stream.write_all(&out).await?;
                    return Ok(());
                }
                // Pong / unknown control → ignore.
                _ => {}
            }
            pos += f.total;
        }

        if !out.is_empty() {
            stream.write_all(&out).await?;
            out.clear();
        }
        if pos > 0 {
            buf.drain(..pos);
            pos = 0;
        }

        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            return Ok(()); // client closed
        }
        buf.extend_from_slice(&tmp[..n]);
    }
}

/// Parse a single frame header + payload out of `buf`. Offsets are relative to
/// the start of `buf` (i.e. the caller's `pos`).
fn parse_frame(buf: &[u8]) -> Parse {
    if buf.len() < 2 {
        return Parse::Incomplete;
    }
    let b0 = buf[0];
    let b1 = buf[1];
    let fin = b0 & 0x80 != 0;
    let opcode = b0 & 0x0F;
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
        if l > MAX_FRAME {
            return Parse::Error;
        }
        (l as usize, 10)
    };

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
        fin,
        opcode,
        mask,
        payload_off: off,
        payload_len,
        total: off + payload_len,
    })
}

/// Write a server-side (unmasked) frame header for `opcode`/`len`.
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
        out.push(if chunk.len() > 1 {
            T[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}
