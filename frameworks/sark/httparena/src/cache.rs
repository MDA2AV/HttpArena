use std::{
    cell::Cell,
    collections::hash_map::RandomState,
    hash::BuildHasher,
    num::NonZero,
    time::{Duration, Instant},
};

use cartel_redis::{
    api::{Commands, decode},
    client::settings,
};
use o3::{
    alloc,
    buffer::storage::Shared,
    depot::map::{self, flat::Table},
    mem::rc,
};

pub const ID: u8 = 11;
pub const USER_TTL: NonZero<u64> = NonZero::<u64>::MIN.saturating_add(29);
pub const MAX_BYTES: usize = 64 * 1024;
const USER_ENTRIES: NonZero<usize> = NonZero::<usize>::MIN.saturating_add(255);
const RESERVE: &[u8] = br#"local value = redis.call('GET', KEYS[1])
if value then return value end
redis.call('SET', KEYS[1], ARGV[1], 'EX', 1)
return ARGV[1]"#;
const FILL: &[u8] = br#"if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
redis.call('SET', KEYS[1], ARGV[2], 'EX', 1)
return 1"#;

pub struct Users {
    entries: Table<Entry>,
    hash: RandomState,
}

struct Entry {
    id: NonZero<i32>,
    admitted_at: Instant,
    body: Shared,
}

impl Entry {
    fn new(id: NonZero<i32>, body: &Shared, admitted_at: Instant) -> Result<Self, rc::Error> {
        Ok(Self {
            id,
            admitted_at,
            body: body.try_clone()?,
        })
    }

    fn live(&self, now: Instant) -> bool {
        now.duration_since(self.admitted_at) < Duration::from_secs(USER_TTL.get())
    }
}

impl Users {
    pub fn new(configured: bool) -> Result<Self, alloc::Error> {
        let plan = if configured {
            map::Plan::fixed::<{ USER_ENTRIES.get() }>()
        } else {
            map::Plan::fixed::<0>()
        };
        Ok(Self {
            entries: Table::try_new(plan)?,
            hash: RandomState::new(),
        })
    }

    pub(crate) fn get(&self, id: NonZero<i32>, now: Instant) -> Result<Option<Shared>, rc::Error> {
        self.entries
            .get(self.hash.hash_one(id), |entry| entry.id == id)
            .filter(|entry| entry.live(now))
            .map(|entry| entry.body.try_clone())
            .transpose()
    }

    pub(crate) fn insert(
        &mut self,
        id: NonZero<i32>,
        body: &Shared,
        now: Instant,
    ) -> Result<(), rc::Error> {
        let hash = self.hash.hash_one(id);
        match self.entries.entry(hash, |entry| entry.id == id) {
            Some(map::Entry::Occupied(mut entry)) => {
                if !entry.get().live(now) {
                    *entry.get_mut() = Entry::new(id, body, now)?;
                }
            }
            Some(map::Entry::Vacant(entry)) => {
                entry.insert(Entry::new(id, body, now)?);
            }
            None => {
                let Some(victim) = self
                    .entries
                    .values()
                    .min_by_key(|entry| entry.admitted_at)
                    .map(|entry| entry.id)
                else {
                    return Ok(());
                };
                let value = Entry::new(id, body, now)?;
                self.entries
                    .retire(self.hash.hash_one(victim), |entry| entry.id == victim);
                let Some(map::Entry::Vacant(entry)) =
                    self.entries.entry(hash, |entry| entry.id == id)
                else {
                    unreachable!("cache")
                };
                entry.insert(value);
            }
        }
        Ok(())
    }
}

pub struct Tokens {
    prefix: [u8; 16],
    issued: Cell<u64>,
}

pub struct Token([u8; 25]);

#[derive(Debug)]
pub struct Exhausted;

impl Tokens {
    pub fn new() -> Result<Self, getrandom::Error> {
        let mut prefix = [0; 16];
        getrandom::fill(&mut prefix)?;
        Ok(Self {
            prefix,
            issued: Cell::new(0),
        })
    }

    pub fn issue(&self) -> Result<Token, Exhausted> {
        let next = self.issued.get().checked_add(1).ok_or(Exhausted)?;
        self.issued.set(next);
        let mut bytes = [0; 25];
        bytes[0] = b'!';
        bytes[1..17].copy_from_slice(&self.prefix);
        bytes[17..].copy_from_slice(&next.to_be_bytes());
        Ok(Token(bytes))
    }
}

impl Token {
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

pub fn reserved(value: &[u8]) -> Option<Token> {
    let bytes: &[u8; 25] = value.try_into().ok()?;
    if bytes[0] == b'!' {
        Some(Token(*bytes))
    } else {
        None
    }
}

pub struct Key {
    bytes: [u8; 16],
    start: usize,
}

pub fn reserve<'region, C: Commands<'region, ID>>(
    redis: C,
    key: &[u8],
    token: &Token,
) -> C::Call<decode::Bytes> {
    redis
        .scripts()
        .eval::<decode::Bytes, _, _>(RESERVE, &[key], &[token.as_bytes()])
}

pub fn fill<'region, C: Commands<'region, ID>>(
    redis: C,
    key: &[u8],
    token: &Token,
    body: &[u8],
) -> C::Call<bool> {
    redis
        .scripts()
        .eval::<bool, _, _>(FILL, &[key], &[token.as_bytes(), body])
}

impl Key {
    pub fn item(id: NonZero<i32>) -> Self {
        Self::new(b"item:", id)
    }

    pub fn user(id: NonZero<i32>) -> Self {
        Self::new(b"user:", id)
    }

    fn new(prefix: &[u8; 5], id: NonZero<i32>) -> Self {
        let mut bytes = [0; 16];
        let mut start = bytes.len();
        let mut value = id.get().unsigned_abs();
        loop {
            start -= 1;
            bytes[start] = b'0' + (value % 10) as u8;
            value /= 10;
            if value == 0 {
                break;
            }
        }
        if id.get() < 0 {
            start -= 1;
            bytes[start] = b'-';
        }
        start -= prefix.len();
        bytes[start..start + prefix.len()].copy_from_slice(prefix);
        Self { bytes, start }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[self.start..]
    }
}

pub fn config(
    waiters: NonZero<usize>,
    configured: bool,
) -> Result<settings::Config, settings::Error> {
    let tasks = if configured { crate::db::TASKS } else { 1 };
    settings::Config::new(settings::Capacities {
        connections: 1,
        admission_waiters: if configured { waiters.get() } else { 1 },
        inflight: tasks,
        request_frame_bytes: if configured { MAX_BYTES + 1024 } else { 1 },
        response_bytes: if configured { 16 * MAX_BYTES } else { 1 },
        response_values: if configured { crate::db::TASKS * 4 } else { 1 },
        response_frame_bytes: if configured { MAX_BYTES + 256 } else { 1 },
        response_frame_values: if configured { 4 } else { 1 },
    })
}
