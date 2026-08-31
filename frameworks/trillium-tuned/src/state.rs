use dashmap::DashMap;
use deadpool_postgres::{
    Config as PgConfig, ManagerConfig, Pool, PoolConfig, RecyclingMethod, Runtime,
};
use deadpool_redis::{Config as RedisConfig, Pool as RedisPool, Runtime as RedisRuntime};
use moka::future::Cache;
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio_postgres::NoTls;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Item {
    pub id: u32,
    pub name: String,
    pub category: String,
    pub price: u32,
    pub quantity: u32,
    pub active: bool,
    pub tags: Vec<String>,
    pub rating: Rating,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Rating {
    pub score: u32,
    pub count: u32,
}

pub struct AppState {
    pub dataset: Arc<Vec<Item>>,
    pub crud_cache: Arc<DashMap<i32, CacheEntry>>,
    /// production-stack L1s. Shared across reuseport workers rather than per-worker: an L1 per
    /// worker would divide the hit rate by the worker count for no benefit, since moka is
    /// already lock-free under concurrent access.
    pub items_l1: Cache<i32, Arc<[u8]>>,
    pub users_l1: Cache<i32, Arc<[u8]>>,
    pub pg: Option<Pool>,
    /// production-stack L2. `None` outside that profile, where nothing sets `REDIS_URL`.
    pub redis: Option<RedisPool>,
}

pub struct CacheEntry {
    pub body: Arc<[u8]>,
    pub expires: Instant,
}

pub const CRUD_CACHE_TTL: Duration = Duration::from_millis(200);

/// production-stack item TTL, at the profile's ceiling. Short on purpose: the profile wants the
/// cache cycling so Postgres keeps seeing traffic.
pub const ITEM_TTL: Duration = Duration::from_secs(1);

/// production-stack user TTL. User rows barely change, so this is effectively a warm cache for
/// the length of a run.
pub const USER_TTL: Duration = Duration::from_secs(30);

/// L1 capacities. Items is sized past the profile's 10,000-id working set so the bound never
/// evicts anything the TTL would not have; users has four rows in the seed.
const ITEMS_L1_CAPACITY: u64 = 16_384;
const USERS_L1_CAPACITY: u64 = 1_024;

pub fn items_l1() -> Cache<i32, Arc<[u8]>> {
    Cache::builder()
        .max_capacity(ITEMS_L1_CAPACITY)
        .time_to_live(ITEM_TTL)
        .build()
}

pub fn users_l1() -> Cache<i32, Arc<[u8]>> {
    Cache::builder()
        .max_capacity(USERS_L1_CAPACITY)
        .time_to_live(USER_TTL)
        .build()
}

pub fn build_redis_pool() -> Option<RedisPool> {
    let url = env::var("REDIS_URL").ok()?;
    let mut cfg = RedisConfig::from_url(url);
    let max_size: usize = env::var("REDIS_MAX_CONN")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(256);
    cfg.pool = Some(deadpool_redis::PoolConfig::new(max_size));
    match cfg.create_pool(Some(RedisRuntime::Tokio1)) {
        Ok(pool) => Some(pool),
        Err(e) => {
            log::warn!("redis pool init failed: {e}");
            None
        }
    }
}

#[derive(Clone)]
pub struct SharedState {
    pub dataset: Arc<Vec<Item>>,
    pub crud_cache: Arc<DashMap<i32, CacheEntry>>,
    pub items_l1: Cache<i32, Arc<[u8]>>,
    pub users_l1: Cache<i32, Arc<[u8]>>,
}

impl SharedState {
    pub fn init() -> Self {
        let dataset_path = env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".into());
        let dataset: Vec<Item> = fs::read(&dataset_path)
            .ok()
            .and_then(|bytes| sonic_rs::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            dataset: Arc::new(dataset),
            crud_cache: Arc::new(DashMap::new()),
            items_l1: items_l1(),
            users_l1: users_l1(),
        }
    }
}

pub fn build_pg_pool() -> Option<Pool> {
    let url = env::var("DATABASE_URL").ok()?;
    let mut cfg = PgConfig::new();
    cfg.url = Some(url);
    cfg.manager = Some(ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    });
    let total: usize = env::var("DATABASE_MAX_CONN")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(256);
    cfg.pool = Some(PoolConfig::new(total));
    cfg.create_pool(Some(Runtime::Tokio1), NoTls).ok()
}
