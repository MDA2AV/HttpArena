use std::{collections::TryReserveError, fs, io, path::Path};

use o3::buffer::storage::Shared;
use sark::http::payload::response::exact::Overflow;
use sark_json::parsing::Decode;

use crate::model::Item;

pub(crate) const LIMIT: usize = 50;

#[derive(Debug)]
pub enum Error {
    Read(io::Error),
    Reserve(TryReserveError),
    Storage(o3::alloc::Exhausted),
    Json(sark_json::parsing::Error<'static>),
    Size(Overflow),
    Empty,
}

#[derive(Debug)]
#[sark_json::json(ordered)]
struct Source {
    #[field(seq, nested)]
    items: Vec<Item>,
}

#[derive(Debug)]
pub struct Dataset {
    pub(crate) items: Vec<Item>,
    pub(crate) bounds: [Bounds; LIMIT + 1],
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Bounds {
    pub(crate) bytes: usize,
    pub(crate) multiplier: u64,
}

impl Dataset {
    pub fn load(path: &Path) -> Result<Self, Error> {
        Self::from_json(fs::read(path).map_err(Error::Read)?)
    }

    pub fn from_json(mut input: Vec<u8>) -> Result<Self, Error> {
        let len = input.len();
        input.try_reserve(10).map_err(Error::Reserve)?;
        input.resize(len + 10, 0);
        input.copy_within(..len, 9);
        input[..9].copy_from_slice(b"{\"items\":");
        input[len + 9] = b'}';
        let input = Shared::try_from(&mut input).map_err(Error::Storage)?;
        let source = Source::decode(input).map_err(Error::Json)?;
        if source.items.is_empty() {
            return Err(Error::Empty);
        }
        let bounds = crate::json::bounds(&source.items).map_err(Error::Size)?;
        Ok(Self {
            items: source.items,
            bounds,
        })
    }
}
