//! `/async-db` and the `/fortunes` query: tokio-postgres behind a
//! deadpool-postgres pool, one pool per worker.

use std::cell::OnceCell;
use std::sync::OnceLock;

use actix_web::{web, HttpResponse};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use serde::{Deserialize, Serialize};
use tokio_postgres::{NoTls, Row};

const QUERY: &str = "SELECT id, name, category, price, quantity, active, tags, rating_score, \
                     rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
const FORTUNES: &str = "SELECT id, message FROM fortune";

/// Workers sharing `DATABASE_MAX_CONN`, recorded by `main` before they start.
static WORKERS: OnceLock<usize> = OnceLock::new();

thread_local! {
    // The app factory runs once per listener on every worker, so the pool is
    // kept per thread: the three listeners of a worker share one pool.
    static POOL: OnceCell<Option<Pool>> = const { OnceCell::new() };
}

#[derive(Deserialize)]
pub struct PriceQuery {
    min: Option<i32>,
    max: Option<i32>,
    limit: Option<i32>,
}

#[derive(Serialize)]
struct DbRating {
    score: i32,
    count: i32,
}

#[derive(Serialize)]
struct DbItem<'a> {
    id: i32,
    name: &'a str,
    category: &'a str,
    price: i32,
    quantity: i32,
    active: bool,
    tags: serde_json::Value,
    rating: DbRating,
}

#[derive(Serialize)]
struct DbList<'a> {
    items: Vec<DbItem<'a>>,
    count: usize,
}

/// Records how many workers split `DATABASE_MAX_CONN` between their pools.
pub fn set_workers(workers: usize) {
    let _ = WORKERS.set(workers.max(1));
}

/// The calling worker's pool, or `None` when `DATABASE_URL` is unset or invalid.
///
/// Every actix-web worker is a single-threaded runtime of its own. A pool
/// shared by all of them hands a worker connections whose socket is driven
/// from whichever worker happened to open it, so each query crosses threads
/// on the way out and again on the way back. With a pool per worker a query
/// never leaves the thread that serves its request.
///
/// Each pool holds its worker's share of `DATABASE_MAX_CONN`, so together
/// they stay within what Postgres accepts. Connections open on first use.
pub fn worker_pool() -> Option<Pool> {
    POOL.with(|pool| pool.get_or_init(open).clone())
}

fn open() -> Option<Pool> {
    let config: tokio_postgres::Config = std::env::var("DATABASE_URL").ok()?.parse().ok()?;
    let max_conn = std::env::var("DATABASE_MAX_CONN")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(256);
    let workers = WORKERS.get().copied().unwrap_or(1);
    let manager = Manager::from_config(
        config,
        NoTls,
        ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        },
    );
    Pool::builder(manager)
        .max_size((max_conn / workers).max(1))
        .build()
        .ok()
}

/// Runs `sql` as a cached prepared statement on a pooled connection. `None`
/// without a pool or on any database error.
async fn query(
    pool: &Option<Pool>,
    sql: &str,
    params: &[&(dyn tokio_postgres::types::ToSql + Sync)],
) -> Option<Vec<Row>> {
    let client = pool.as_ref()?.get().await.ok()?;
    let statement = client.prepare_cached(sql).await.ok()?;
    client.query(&statement, params).await.ok()
}

fn item(row: &Row) -> DbItem<'_> {
    DbItem {
        id: row.get(0),
        name: row.get(1),
        category: row.get(2),
        price: row.get(3),
        quantity: row.get(4),
        active: row.get(5),
        tags: row.get(6),
        rating: DbRating {
            score: row.get(7),
            count: row.get(8),
        },
    }
}

/// All `fortune` rows as `(id, message)`, or `None` without a database or on
/// a database error.
pub async fn fortunes(pool: &Option<Pool>) -> Option<Vec<Row>> {
    query(pool, FORTUNES, &[]).await
}

/// Items in the requested price range. Without a database or on a database
/// error the answer is `500`, so a failed query is counted as one instead of
/// passing for an empty result.
pub async fn async_db(
    params: web::Query<PriceQuery>,
    pool: web::Data<Option<Pool>>,
) -> HttpResponse {
    let min = params.min.unwrap_or(10);
    let max = params.max.unwrap_or(50);
    let limit = i64::from(params.limit.unwrap_or(50).clamp(1, 50));

    let Some(rows) = query(&pool, QUERY, &[&min, &max, &limit]).await else {
        return HttpResponse::InternalServerError().finish();
    };
    let items: Vec<_> = rows.iter().map(item).collect();
    HttpResponse::Ok().json(&DbList {
        count: items.len(),
        items,
    })
}
