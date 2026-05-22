use crate::{
    handlers::json_response,
    state::{AppState, Rating},
};
use deadpool_postgres::Pool;
use querystrong::QueryStrong;
use serde::Serialize;
use std::sync::Arc;
use trillium::Conn;

#[derive(Debug, Serialize)]
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

#[derive(Debug, Serialize)]
struct DbResponse {
    items: Vec<DbItem>,
    count: usize,
}

const ASYNC_DB_QUERY: &str = "SELECT id, name, category, price, quantity, active, tags, \
                              rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 \
                              LIMIT $3";

pub async fn async_db(conn: Conn) -> Conn {
    let qs = QueryStrong::parse(conn.querystring());
    let min: i32 = qs.get_str("min").and_then(|s| s.parse().ok()).unwrap_or(10);
    let max: i32 = qs.get_str("max").and_then(|s| s.parse().ok()).unwrap_or(50);
    let limit: i64 = qs
        .get_str("limit")
        .and_then(|s| s.parse().ok())
        .unwrap_or(50)
        .clamp(1, 50);

    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));
    let Some(pool) = &state.pg else {
        return json_response(conn, br#"{"items":[],"count":0}"#.to_vec());
    };

    let items = match query_async_db(pool, min, max, limit).await {
        Ok(items) => items,
        Err(e) => {
            log::warn!("async-db query failed: {e}");
            return json_response(conn, br#"{"items":[],"count":0}"#.to_vec());
        }
    };

    let count = items.len();
    let body = sonic_rs::to_vec(&DbResponse { items, count }).unwrap_or_default();
    json_response(conn, body)
}

async fn query_async_db(
    pool: &Pool,
    min: i32,
    max: i32,
    limit: i64,
) -> Result<Vec<DbItem>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client.prepare_cached(ASYNC_DB_QUERY).await?;
    let rows = client.query(&stmt, &[&min, &max, &limit]).await?;
    Ok(rows
        .into_iter()
        .map(|row| DbItem {
            id: row.get(0),
            name: row.get(1),
            category: row.get(2),
            price: row.get(3),
            quantity: row.get(4),
            active: row.get(5),
            tags: row.get::<_, serde_json::Value>(6),
            rating: Rating {
                score: row.get::<_, i32>(7) as u32,
                count: row.get::<_, i32>(8) as u32,
            },
        })
        .collect())
}
