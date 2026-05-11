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

pub struct AppState {
    pub dataset: Vec<Item>,
    pub pg: Option<Pool>,
    pub crud_cache: DashMap<i32, CacheEntry>,
}

pub struct CacheEntry {
    pub body: Vec<u8>,
    pub expires: Instant,
}

pub const CRUD_CACHE_TTL: Duration = Duration::from_millis(200);

impl AppState {
    pub fn init() -> Arc<Self> {
        let dataset_path =
            std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".into());
        let dataset = std::fs::read(&dataset_path)
            .ok()
            .and_then(|bytes| sonic_rs::from_slice(&bytes).ok())
            .unwrap_or_default();

        let pg = std::env::var("DATABASE_URL").ok().and_then(|url| {
            let mut cfg = PgConfig::new();
            cfg.url = Some(url);
            cfg.manager = Some(ManagerConfig {
                recycling_method: RecyclingMethod::Fast,
            });
            let max_size: usize = std::env::var("DATABASE_MAX_CONN")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(256);
            cfg.pool = Some(deadpool_postgres::PoolConfig::new(max_size));
            cfg.create_pool(Some(Runtime::Tokio1), NoTls).ok()
        });

        Arc::new(Self {
            dataset,
            pg,
            crud_cache: DashMap::new(),
        })
    }
}
