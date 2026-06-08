use dashmap::DashMap;
use deadpool_postgres::{
    Config as PgConfig, ManagerConfig, Pool, PoolConfig, RecyclingMethod, Runtime,
};
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
    pub pg: Option<Pool>,
}

pub struct CacheEntry {
    pub body: Arc<[u8]>,
    pub expires: Instant,
}

pub const CRUD_CACHE_TTL: Duration = Duration::from_millis(200);

#[derive(Clone)]
pub struct SharedState {
    pub dataset: Arc<Vec<Item>>,
    pub crud_cache: Arc<DashMap<i32, CacheEntry>>,
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
