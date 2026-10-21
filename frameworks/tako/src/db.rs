use std::time::Duration;

use deadpool_postgres::{Config, ManagerConfig, Pool, PoolConfig, RecyclingMethod, Runtime};
use moka::sync::Cache;
use serde::{Deserialize, Serialize};
use tako::extractors::header_map::HeaderMap;
use tako::extractors::json::Json;
use tako::extractors::path::Path;
use tako::extractors::query::Query;
use tako::extractors::state::State;
use tako::header::{CONTENT_TYPE, HeaderValue};
use tako::responder::Responder;
use tako::types::{BoxError, Response};
use tako::{Bytes, StatusCode};
use tokio_postgres::{NoTls, Row};

use crate::AppRef;

const RANGE: &str = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
                     FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
const ITEM: &str = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
                    FROM items WHERE id = $1";
const UPDATE: &str = "UPDATE items SET name = $2, price = $3, quantity = $4 WHERE id = $1";
const USER: &str = "SELECT id, name, email, plan FROM users WHERE id = $1";

pub struct Db {
    pool: Option<Pool>,
    items: Cache<i32, Bytes>,
    users: Cache<i32, Bytes>,
}

impl Db {
    pub fn from_env() -> Self {
        let pool = std::env::var("DATABASE_URL").ok().and_then(|url| {
            let size = std::env::var("DATABASE_MAX_CONN")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(256);
            let mut config = Config::new();
            config.url = Some(url);
            config.manager = Some(ManagerConfig {
                recycling_method: RecyclingMethod::Fast,
            });
            config.pool = Some(PoolConfig::new(size));
            config.create_pool(Some(Runtime::Tokio1), NoTls).ok()
        });
        Self {
            pool,
            items: Cache::builder()
                .max_capacity(16_384)
                .time_to_live(Duration::from_secs(1))
                .build(),
            users: Cache::builder()
                .max_capacity(1_024)
                .time_to_live(Duration::from_secs(30))
                .build(),
        }
    }

    async fn query(
        &self,
        sql: &str,
        params: &[&(dyn tokio_postgres::types::ToSql + Sync)],
    ) -> Result<Vec<Row>, BoxError> {
        let client = self
            .pool
            .as_ref()
            .ok_or("DATABASE_URL is not set")?
            .get()
            .await?;
        let statement = client.prepare_cached(sql).await?;
        Ok(client.query(&statement, params).await?)
    }
}

#[derive(Serialize)]
struct Rating {
    score: i32,
    count: i32,
}

#[derive(Serialize)]
struct DbItem {
    id: i32,
    name: String,
    category: String,
    price: i32,
    quantity: i32,
    active: bool,
    tags: serde_json::Value,
    rating: Rating,
}

impl From<&Row> for DbItem {
    fn from(row: &Row) -> Self {
        Self {
            id: row.get(0),
            name: row.get(1),
            category: row.get(2),
            price: row.get(3),
            quantity: row.get(4),
            active: row.get(5),
            tags: row.get(6),
            rating: Rating {
                score: row.get(7),
                count: row.get(8),
            },
        }
    }
}

#[derive(Serialize)]
pub struct DbItems {
    items: Vec<DbItem>,
    count: usize,
}

#[derive(Deserialize)]
pub struct PriceRange {
    min: Option<i32>,
    max: Option<i32>,
    limit: Option<i64>,
}

#[derive(Serialize)]
struct User {
    id: i32,
    name: String,
    email: String,
    plan: String,
}

#[derive(Deserialize)]
pub struct ItemUpdate {
    name: String,
    price: i32,
    quantity: i32,
}

pub async fn price_range(
    State(app): State<AppRef>,
    Query(range): Query<PriceRange>,
) -> Json<DbItems> {
    let min = range.min.unwrap_or(10);
    let max = range.max.unwrap_or(50);
    let limit = range.limit.unwrap_or(50).clamp(1, 50);
    let items: Vec<DbItem> = match app.db.query(RANGE, &[&min, &max, &limit]).await {
        Ok(rows) => rows.iter().map(DbItem::from).collect(),
        Err(_) => Vec::new(),
    };
    Json(DbItems {
        count: items.len(),
        items,
    })
}

fn cached(body: Bytes, cache: &'static str) -> Response {
    let mut response = body.into_response();
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert("x-cache", HeaderValue::from_static(cache));
    response
}

async fn lookup<T: Serialize>(
    cache: &Cache<i32, Bytes>,
    id: i32,
    load: impl Future<Output = Result<Option<T>, BoxError>>,
) -> Response {
    if let Some(body) = cache.get(&id) {
        return cached(body, "HIT");
    }
    match load.await {
        Ok(Some(value)) => match serde_json::to_vec(&value) {
            Ok(body) => {
                let body = Bytes::from(body);
                cache.insert(id, body.clone());
                cached(body, "MISS")
            }
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        },
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}

pub async fn read_item(State(app): State<AppRef>, Path(id): Path<i32>) -> Response {
    let load = async {
        let rows = app.db.query(ITEM, &[&id]).await?;
        Ok(rows.first().map(DbItem::from))
    };
    lookup(&app.db.items, id, load).await
}

pub async fn write_item(
    State(app): State<AppRef>,
    Path(id): Path<i32>,
    Json(update): Json<ItemUpdate>,
) -> StatusCode {
    let result = app
        .db
        .query(
            UPDATE,
            &[&id, &update.name, &update.price, &update.quantity],
        )
        .await;
    app.db.items.invalidate(&id);
    match result {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}

pub async fn me(State(app): State<AppRef>, HeaderMap(headers): HeaderMap) -> Response {
    let Some(id) = headers
        .get("x-user-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<i32>().ok())
    else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let load = async {
        let rows = app.db.query(USER, &[&id]).await?;
        Ok(rows.first().map(|row| User {
            id: row.get(0),
            name: row.get(1),
            email: row.get(2),
            plan: row.get(3),
        }))
    };
    lookup(&app.db.users, id, load).await
}
