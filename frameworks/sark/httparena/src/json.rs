use std::{convert::Infallible, slice};

use sark::http::payload::response::exact::Overflow;
use sark_json::writing::{TryMaxSize, TrySize};

use crate::{
    dataset::{Bounds, Dataset, LIMIT},
    model::Item,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Overflow,
}

#[sark_json::json(encode)]
struct ItemView<'a> {
    #[field(flatten)]
    item: &'a Item,
    total: u64,
}

struct Items<'a> {
    rows: &'a [Item],
    multiplier: u64,
    bound: usize,
}

struct Iter<'a> {
    rows: slice::Iter<'a, Item>,
    multiplier: u64,
}

impl<'a> IntoIterator for &Items<'a> {
    type Item = ItemView<'a>;
    type IntoIter = Iter<'a>;

    fn into_iter(self) -> Self::IntoIter {
        Iter {
            rows: self.rows.iter(),
            multiplier: self.multiplier,
        }
    }
}

impl<'a> Iterator for Iter<'a> {
    type Item = ItemView<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        let item = self.rows.next()?;
        Some(ItemView {
            item,
            total: item.price.wrapping_mul(item.quantity) * self.multiplier,
        })
    }
}

#[sark_json::json(encode)]
pub struct Listing<'a> {
    #[field(seq, nested)]
    items: Items<'a>,
    count: u64,
}

impl TryMaxSize for Listing<'_> {
    type Error = Infallible;

    fn try_max_size(&self) -> Result<usize, Self::Error> {
        Ok(self.items.bound)
    }
}

pub(crate) fn bounds(items: &[Item]) -> Result<[Bounds; LIMIT + 1], Overflow> {
    let empty = Listing {
        items: Items {
            rows: &[],
            multiplier: 0,
            bound: 0,
        },
        count: LIMIT as u64,
    };
    let mut bounds = [Bounds {
        bytes: empty.try_size()?,
        multiplier: u64::MAX,
    }; LIMIT + 1];
    for (index, item) in items.iter().take(LIMIT).enumerate() {
        let size = ItemView {
            item,
            total: u64::MAX,
        }
        .try_size()?;
        let size = Overflow::try_add(size, usize::from(index != 0))?;
        let multiplier = match item.price.checked_mul(item.quantity) {
            Some(0) => u64::MAX,
            Some(total) => u64::MAX / total,
            None => 0,
        };
        bounds[index + 1] = Bounds {
            bytes: Overflow::try_add(bounds[index].bytes, size)?,
            multiplier: bounds[index].multiplier.min(multiplier),
        };
    }
    Ok(bounds)
}

pub fn items(dataset: &Dataset, count: usize, multiplier: u64) -> Result<Listing<'_>, Error> {
    let count = count.clamp(1, LIMIT).min(dataset.items.len());
    let rows = &dataset.items[..count];
    let bounds = dataset.bounds[count];
    if multiplier > bounds.multiplier {
        return Err(Error::Overflow);
    }
    Ok(Listing {
        items: Items {
            rows,
            multiplier,
            bound: bounds.bytes,
        },
        count: count as u64,
    })
}
