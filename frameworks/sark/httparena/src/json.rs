use o3::buffer::Owned;
use sark::json::JsonEncode;
use sark_core::http::LocalFrameBytes;

use crate::dataset::DATASET;

#[sark_gen::json(ordered)]
struct StdRating {
    score: u64,
    count: u64,
}

#[sark_gen::json(ordered)]
struct StdItem {
    id: u64,
    name: LocalFrameBytes,
    category: LocalFrameBytes,
    price: u64,
    quantity: u64,
    active: bool,
    #[field(seq)]
    tags: Vec<LocalFrameBytes>,
    #[field(nested)]
    rating: StdRating,
    total: u64,
}

#[sark_gen::json(ordered)]
struct StdItems {
    #[field(seq, nested)]
    items: Vec<StdItem>,
    count: u64,
}

pub struct JsonOut;

impl JsonOut {
    pub fn sum_body(a: u64, b: u64) -> Owned {
        let mut body = Owned::with_capacity(24);
        Self::push_u64(&mut body, a.wrapping_add(b));
        body
    }

    pub fn items_standard(count: usize, m: u64) -> Owned {
        let count = count.clamp(1, 50);
        let m = m.max(1);
        let items = DATASET
            .iter()
            .take(count)
            .map(|item| StdItem {
                id: item.id as u64,
                name: LocalFrameBytes::from_slice(item.name),
                category: LocalFrameBytes::from_slice(item.category),
                price: item.price as u64,
                quantity: item.quantity as u64,
                active: item.active,
                tags: item
                    .tags
                    .iter()
                    .map(|t| LocalFrameBytes::from_slice(t))
                    .collect(),
                rating: StdRating {
                    score: item.rating_score as u64,
                    count: item.rating_count as u64,
                },
                total: (item.price as u64) * (item.quantity as u64) * m,
            })
            .collect();
        StdItems {
            items,
            count: count as u64,
        }
        .encode_json()
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
}
