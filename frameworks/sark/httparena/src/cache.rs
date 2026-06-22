use std::cell::RefCell;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::model::ItemRow;

pub struct ItemCache {
    inner: RefCell<HashMap<i32, (ItemRow, Instant)>>,
    ttl: Duration,
}

impl ItemCache {
    pub fn new(ttl: Duration) -> Self {
        Self {
            inner: RefCell::new(HashMap::with_capacity(1024)),
            ttl,
        }
    }

    pub fn get(&self, id: i32) -> Option<ItemRow> {
        let mut map = self.inner.borrow_mut();
        if let Some((row, ts)) = map.get(&id) {
            if ts.elapsed() < self.ttl {
                return Some(row.clone());
            }
            map.remove(&id);
        }
        None
    }

    pub fn insert(&self, id: i32, row: ItemRow) {
        self.inner.borrow_mut().insert(id, (row, Instant::now()));
    }

    pub fn invalidate(&self, id: i32) {
        self.inner.borrow_mut().remove(&id);
    }
}
