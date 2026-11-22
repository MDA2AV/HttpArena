use axum::{
    body::Body,
    extract::Request,
    http::{
        HeaderValue, StatusCode,
        header::{CONNECTION, SEC_WEBSOCKET_ACCEPT, SEC_WEBSOCKET_KEY, UPGRADE},
    },
    response::Response,
};
use hyper_util::rt::TokioIo;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const WS_GUID: &[u8] = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_FRAME: u64 = 16 << 20;
const READ_CAP: usize = 16 * 1024;

const HDR_UPGRADE_WS: HeaderValue = HeaderValue::from_static("websocket");
const HDR_CONN_UPGRADE: HeaderValue = HeaderValue::from_static("Upgrade");

pub async fn ws_handler(req: Request) -> Response {
    let is_upgrade = req
        .headers()
        .get(UPGRADE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.eq_ignore_ascii_case("websocket"));
    let Some(key) = req
        .headers()
        .get(SEC_WEBSOCKET_KEY)
        .and_then(|v| v.to_str().ok())
        .filter(|_| is_upgrade)
    else {
        return Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .body(Body::empty())
            .unwrap();
    };

    let accept = ws_accept(key.as_bytes());
    let accept_hdr = HeaderValue::from_bytes(&accept).expect("valid base64 header");

    tokio::spawn(async move {
        if let Ok(upgraded) = hyper::upgrade::on(req).await {
            let _ = echo_loop(TokioIo::new(upgraded)).await;
        }
    });

    Response::builder()
        .status(StatusCode::SWITCHING_PROTOCOLS)
        .header(UPGRADE, HDR_UPGRADE_WS)
        .header(CONNECTION, HDR_CONN_UPGRADE)
        .header(SEC_WEBSOCKET_ACCEPT, accept_hdr)
        .body(Body::empty())
        .unwrap()
}

#[derive(Clone, Copy)]
struct WsFrame {
    fin: bool,
    opcode: u8,
    mask: Option<[u8; 4]>,
    payload_off: usize,
    payload_len: usize,
    total: usize,
}

enum Parse {
    Frame(WsFrame),
    Incomplete,
    Error,
}

async fn echo_loop<S>(mut io: S) -> std::io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut buf = Vec::<u8>::with_capacity(READ_CAP);
    let mut out = Vec::<u8>::with_capacity(READ_CAP);

    loop {
        if buf.capacity() - buf.len() < 4096 {
            buf.reserve(READ_CAP);
        }
        let n = io.read_buf(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }

        let mut pos = 0usize;
        loop {
            let f = match parse_frame(&buf[pos..]) {
                Parse::Frame(f) => f,
                Parse::Incomplete => break,
                Parse::Error => return Ok(()),
            };

            let start = pos + f.payload_off;
            let end = start + f.payload_len;
            if let Some(mask) = f.mask {
                apply_mask(&mut buf[start..end], mask);
            }

            match f.opcode {
                0x0..=0x2 => {
                    push_header(&mut out, f.fin, f.opcode, f.payload_len);
                    out.extend_from_slice(&buf[start..end]);
                }
                0x9 => {
                    push_header(&mut out, true, 0xA, f.payload_len);
                    out.extend_from_slice(&buf[start..end]);
                }
                0x8 => {
                    push_header(&mut out, true, 0x8, f.payload_len);
                    out.extend_from_slice(&buf[start..end]);
                    io.write_all(&out).await?;
                    return Ok(());
                }
                _ => {}
            }
            pos += f.total;
        }

        if !out.is_empty() {
            io.write_all(&out).await?;
            out.clear();
        }
        if pos == buf.len() {
            buf.clear();
        } else if pos > 0 {
            let rem = buf.len() - pos;
            buf.copy_within(pos.., 0);
            buf.truncate(rem);
        }
    }
}

#[inline]
fn apply_mask(payload: &mut [u8], mask: [u8; 4]) {
    let mask8 = u64::from_ne_bytes([
        mask[0], mask[1], mask[2], mask[3], mask[0], mask[1], mask[2], mask[3],
    ]);
    let mut chunks = payload.chunks_exact_mut(8);
    for chunk in &mut chunks {
        let word = u64::from_ne_bytes(chunk.try_into().unwrap()) ^ mask8;
        chunk.copy_from_slice(&word.to_ne_bytes());
    }
    for (i, byte) in chunks.into_remainder().iter_mut().enumerate() {
        *byte ^= mask[i & 3];
    }
}

#[inline]
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

    Parse::Frame(WsFrame {
        fin,
        opcode,
        mask,
        payload_off: off,
        payload_len,
        total: off + payload_len,
    })
}

#[inline]
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

fn ws_accept(key: &[u8]) -> [u8; 28] {
    let mut input = [0u8; 128];
    let n = key.len().min(input.len() - WS_GUID.len());
    input[..n].copy_from_slice(&key[..n]);
    input[n..n + WS_GUID.len()].copy_from_slice(WS_GUID);
    let digest = sha1(&input[..n + WS_GUID.len()]);
    base64_20(&digest)
}

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut msg = Vec::with_capacity(data.len() + 72);
    msg.extend_from_slice(data);
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
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1u32),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC_u32),
                _ => (b ^ c ^ d, 0xCA62_C1D6u32),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
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

fn base64_20(src: &[u8; 20]) -> [u8; 28] {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = [b'='; 28];
    let mut o = 0usize;
    let mut i = 0usize;
    while i + 3 <= 20 {
        let v = (u32::from(src[i]) << 16) | (u32::from(src[i + 1]) << 8) | u32::from(src[i + 2]);
        out[o] = TABLE[((v >> 18) & 0x3f) as usize];
        out[o + 1] = TABLE[((v >> 12) & 0x3f) as usize];
        out[o + 2] = TABLE[((v >> 6) & 0x3f) as usize];
        out[o + 3] = TABLE[(v & 0x3f) as usize];
        i += 3;
        o += 4;
    }
    // 20 % 3 == 2 remaining bytes (src[18], src[19])
    let v = (u32::from(src[18]) << 16) | (u32::from(src[19]) << 8);
    out[24] = TABLE[((v >> 18) & 0x3f) as usize];
    out[25] = TABLE[((v >> 12) & 0x3f) as usize];
    out[26] = TABLE[((v >> 6) & 0x3f) as usize];
    out[27] = b'=';
    out
}
