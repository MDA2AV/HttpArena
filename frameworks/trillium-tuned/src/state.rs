use dashmap::DashMap;
use deadpool_postgres::{Config as PgConfig, ManagerConfig, Pool, RecyclingMethod, Runtime};
use serde::{Deserialize, Serialize};
use std::{
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

/// State each handler reads from `conn.shared_state`.
///
/// `dataset` and `crud_cache` are `Arc`-wrapped so workers share them (cross-worker cache hits
/// satisfy the CRUD spec's "in-process cache" rule). `pg` is per-worker — its connections, and
/// the tokio_postgres driver tasks behind them, live on whichever worker's `current_thread`
/// runtime created the pool. Sharing one pool across runtimes would risk getting a connection
/// driven by another runtime back from `pool.get()`.
pub struct AppState {
    pub dataset: Arc<Vec<Item>>,
    pub crud_cache: Arc<DashMap<i32, CacheEntry>>,
    pub pg: Option<Pool>,
}

pub struct CacheEntry {
    pub body: Vec<u8>,
    pub expires: Instant,
}

pub const CRUD_CACHE_TTL: Duration = Duration::from_millis(200);

/// Cross-worker pieces. Built once in main, cloned (cheaply, Arc) into each worker's `AppState`.
#[derive(Clone)]
pub struct SharedState {
    pub dataset: Arc<Vec<Item>>,
    pub crud_cache: Arc<DashMap<i32, CacheEntry>>,
}

impl SharedState {
    pub fn init() -> Self {
        let dataset_path =
            std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".into());
        let dataset: Vec<Item> = std::fs::read(&dataset_path)
            .ok()
            .and_then(|bytes| sonic_rs::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            dataset: Arc::new(dataset),
            crud_cache: Arc::new(DashMap::new()),
        }
    }
}

/// Build the per-worker postgres pool. Returns `None` when `DATABASE_URL` is unset.
///
/// Must be called from inside the worker's tokio runtime so the connections, when first
/// established, register their I/O resources with that runtime's reactor.
pub fn build_pg_pool(workers: usize) -> Option<Pool> {
    let url = std::env::var("DATABASE_URL").ok()?;
    let mut cfg = PgConfig::new();
    cfg.url = Some(url);
    cfg.manager = Some(ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    });
    let total: usize = std::env::var("DATABASE_MAX_CONN")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(256);
    let per_worker = (total / workers.max(1)).max(2);
    cfg.pool = Some(deadpool_postgres::PoolConfig::new(per_worker));
    cfg.create_pool(Some(Runtime::Tokio1), NoTls).ok()
}
