use std::{
    convert::Infallible,
    pin::Pin,
    task::{Context, Poll},
};

use axum::{
    body::{Body, Bytes},
    http::{
        HeaderMap, HeaderName, HeaderValue, StatusCode,
        header::CONTENT_TYPE,
    },
    response::Response,
};
use http_body::{Body as HttpBody, Frame, SizeHint};

const APP_GRPC: HeaderValue = HeaderValue::from_static("application/grpc");
const GRPC_STATUS_NAME: HeaderName = HeaderName::from_static("grpc-status");
const GRPC_STATUS_OK: HeaderValue = HeaderValue::from_static("0");

struct GrpcReplyBody {
    data: Option<Bytes>,
    sent_trailers: bool,
}

impl GrpcReplyBody {
    fn new(data: Bytes) -> Self {
        Self {
            data: Some(data),
            sent_trailers: false,
        }
    }
}

impl HttpBody for GrpcReplyBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        if let Some(data) = self.data.take() {
            return Poll::Ready(Some(Ok(Frame::data(data))));
        }
        if !self.sent_trailers {
            self.sent_trailers = true;
            let mut trailers = HeaderMap::with_capacity(1);
            trailers.insert(GRPC_STATUS_NAME, GRPC_STATUS_OK);
            return Poll::Ready(Some(Ok(Frame::trailers(trailers))));
        }
        Poll::Ready(None)
    }

    fn is_end_stream(&self) -> bool {
        self.data.is_none() && self.sent_trailers
    }

    fn size_hint(&self) -> SizeHint {
        let len = self.data.as_ref().map_or(0, Bytes::len) as u64;
        SizeHint::with_exact(len)
    }
}

#[inline]
fn decode_varint(buf: &[u8], pos: &mut usize) -> Option<u64> {
    let mut val = 0u64;
    let mut shift = 0u32;
    while *pos < buf.len() {
        let byte = buf[*pos];
        *pos += 1;
        val |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(val);
        }
        shift += 7;
        if shift >= 70 {
            return None;
        }
    }
    None
}

#[inline]
fn decode_sum_request(payload: &[u8]) -> Option<(i32, i32)> {
    let mut pos = 0usize;
    let mut a = 0i32;
    let mut b = 0i32;
    while pos < payload.len() {
        let tag = decode_varint(payload, &mut pos)?;
        let field = tag >> 3;
        let wire = tag & 0x07;
        match (field, wire) {
            (1, 0) => a = decode_varint(payload, &mut pos)? as i32,
            (2, 0) => b = decode_varint(payload, &mut pos)? as i32,
            (_, 0) => {
                decode_varint(payload, &mut pos)?;
            }
            (_, 1) => {
                pos = pos.checked_add(8)?;
                if pos > payload.len() {
                    return None;
                }
            }
            (_, 2) => {
                let len = usize::try_from(decode_varint(payload, &mut pos)?).ok()?;
                pos = pos.checked_add(len)?;
                if pos > payload.len() {
                    return None;
                }
            }
            (_, 5) => {
                pos = pos.checked_add(4)?;
                if pos > payload.len() {
                    return None;
                }
            }
            _ => return None,
        }
    }
    Some((a, b))
}

#[inline]
fn encode_sum_reply_frame(result: i32) -> Bytes {
    let mut frame = [0u8; 16];
    let mut n = 5usize;
    if result != 0 {
        frame[n] = 0x08; // field 1, varint
        n += 1;
        // Proto3 int32 encodes negative values as 10-byte sign-extended two's complement u64.
        let mut v = i64::from(result) as u64;
        loop {
            let byte = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                frame[n] = byte;
                n += 1;
                break;
            }
            frame[n] = byte | 0x80;
            n += 1;
        }
    }
    let msg_len = (n - 5) as u32;
    frame[1..5].copy_from_slice(&msg_len.to_be_bytes());
    Bytes::copy_from_slice(&frame[..n])
}

pub async fn get_sum(body: Bytes) -> Result<Response, StatusCode> {
    if body.len() < 5 || body[0] != 0 {
        return Err(StatusCode::BAD_REQUEST);
    }
    let msg_len = u32::from_be_bytes([body[1], body[2], body[3], body[4]]) as usize;
    let payload = body.get(5..5 + msg_len).ok_or(StatusCode::BAD_REQUEST)?;
    let (a, b) = decode_sum_request(payload).ok_or(StatusCode::BAD_REQUEST)?;
    let reply = encode_sum_reply_frame(a.wrapping_add(b));

    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, APP_GRPC)
        .body(Body::new(GrpcReplyBody::new(reply)))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}
