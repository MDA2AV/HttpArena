use o3::buffer::Owned;

use crate::dataset::DATASET;
use crate::model::{Item, ItemRow};

pub struct JsonOut;

impl JsonOut {
    pub fn sum_body(a: u64, b: u64) -> Owned {
        let mut body = Owned::with_capacity(24);
        Self::push_u64(&mut body, a.wrapping_add(b));
        body
    }

    pub fn items_body(count: usize, m: u64) -> Owned {
        let count = count.clamp(1, 50);
        let m = m.max(1);
        let mut body = Owned::with_capacity(count * 200 + 32);
        body.extend_from_slice(br#"{"items":["#);
        for (i, item) in DATASET.iter().take(count).enumerate() {
            if i > 0 {
                body.extend_from_slice(b",");
            }
            Self::push_item_with_total(&mut body, item, m);
        }
        body.extend_from_slice(br#"],"count":"#);
        Self::push_u64(&mut body, count as u64);
        body.extend_from_slice(b"}");
        body
    }

    pub fn push_u64(buf: &mut Owned, value: u64) {
        let mut tmp = [0u8; 20];
        let mut v = value;
        let mut i = tmp.len();
        loop {
            i -= 1;
            tmp[i] = b'0' + (v % 10) as u8;
            v /= 10;
            if v == 0 {
                break;
            }
        }
        buf.extend_from_slice(&tmp[i..]);
    }

    pub fn push_bool(buf: &mut Owned, value: bool) {
        buf.extend_from_slice(if value { b"true" } else { b"false" });
    }

    pub fn push_str_escaped(buf: &mut Owned, s: &[u8]) {
        for &b in s {
            match b {
                b'"' => buf.extend_from_slice(b"\\\""),
                b'\\' => buf.extend_from_slice(b"\\\\"),
                b'\n' => buf.extend_from_slice(b"\\n"),
                b'\r' => buf.extend_from_slice(b"\\r"),
                b'\t' => buf.extend_from_slice(b"\\t"),
                0x00..=0x1f => {
                    let hex = b"0123456789abcdef";
                    buf.extend_from_slice(b"\\u00");
                    buf.extend_from_slice(&[hex[(b >> 4) as usize], hex[(b & 0x0f) as usize]]);
                }
                _ => buf.extend_from_slice(&[b]),
            }
        }
    }

    pub fn push_html_escaped(buf: &mut Owned, s: &[u8]) {
        for &b in s {
            match b {
                b'<' => buf.extend_from_slice(b"&lt;"),
                b'>' => buf.extend_from_slice(b"&gt;"),
                b'&' => buf.extend_from_slice(b"&amp;"),
                b'"' => buf.extend_from_slice(b"&quot;"),
                b'\'' => buf.extend_from_slice(b"&#39;"),
                _ => buf.extend_from_slice(&[b]),
            }
        }
    }

    pub fn push_item_with_total(buf: &mut Owned, item: &Item, m: u64) {
        buf.extend_from_slice(br#"{"id":"#);
        Self::push_u64(buf, item.id as u64);
        buf.extend_from_slice(br#","name":""#);
        buf.extend_from_slice(item.name);
        buf.extend_from_slice(br#"","category":""#);
        buf.extend_from_slice(item.category);
        buf.extend_from_slice(br#"","price":"#);
        Self::push_u64(buf, item.price as u64);
        buf.extend_from_slice(br#","quantity":"#);
        Self::push_u64(buf, item.quantity as u64);
        buf.extend_from_slice(br#","active":"#);
        Self::push_bool(buf, item.active);
        buf.extend_from_slice(br#","tags":["#);
        for (i, tag) in item.tags.iter().enumerate() {
            if i > 0 {
                buf.extend_from_slice(b",");
            }
            buf.extend_from_slice(b"\"");
            buf.extend_from_slice(tag);
            buf.extend_from_slice(b"\"");
        }
        buf.extend_from_slice(br#"],"rating":{"score":"#);
        Self::push_u64(buf, item.rating_score as u64);
        buf.extend_from_slice(br#","count":"#);
        Self::push_u64(buf, item.rating_count as u64);
        let total = (item.price as u64) * (item.quantity as u64) * m;
        buf.extend_from_slice(br#"},"total":"#);
        Self::push_u64(buf, total);
        buf.extend_from_slice(b"}");
    }

    pub fn push_item_row(buf: &mut Owned, row: &ItemRow) {
        buf.extend_from_slice(br#"{"id":"#);
        Self::push_u64(buf, row.id as u64);
        buf.extend_from_slice(br#","name":""#);
        Self::push_str_escaped(buf, row.name.as_bytes());
        buf.extend_from_slice(br#"","category":""#);
        Self::push_str_escaped(buf, row.category.as_bytes());
        buf.extend_from_slice(br#"","price":"#);
        Self::push_u64(buf, row.price as u64);
        buf.extend_from_slice(br#","quantity":"#);
        Self::push_u64(buf, row.quantity as u64);
        buf.extend_from_slice(br#","active":"#);
        Self::push_bool(buf, row.active);
        buf.extend_from_slice(br#","tags":"#);
        buf.extend_from_slice(row.tags.as_str().as_bytes());
        buf.extend_from_slice(br#","rating":{"score":"#);
        Self::push_u64(buf, row.rating_score as u64);
        buf.extend_from_slice(br#","count":"#);
        Self::push_u64(buf, row.rating_count as u64);
        buf.extend_from_slice(b"}}");
    }
}
