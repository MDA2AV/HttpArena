//! `/async-db` and the `/fortunes` query: tokio-postgres driven over ntex
//! `Io` (through ntex-io's tokio `AsyncRead`/`AsyncWrite` impls) on the native
//! runtime, pooled per worker with deadpool's unmanaged pool.

use std::{cell::OnceCell, str::FromStr, sync::OnceLock, time::Duration};

use deadpool::unmanaged::{Object, Pool};
use ntex::web::{self, HttpResponse};
use serde::Serialize;
use tokio_postgres::{Client, Config, NoTls, Row, Statement, config::Host, types::ToSql};

const QUERY: &str = "SELECT id, name, category, price, quantity, active, tags, rating_score, \
                     rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
const FORTUNES: &str = "SELECT id, message FROM fortune";
const RECONNECT_DELAY: Duration = Duration::from_secs(1);
const CHECKOUT_TIMEOUT: Duration = Duration::from_secs(5);
// While nothing is connected, a query rechecks this many times before failing.
const NOT_CONNECTED_RETRIES: u32 = 5;
const NOT_CONNECTED_DELAY: Duration = Duration::from_millis(200);

/// Workers sharing `DATABASE_MAX_CONN`, recorded by `main` before they start.
/// ntex pins each worker thread to one CPU, so `available_parallelism()` on a
/// worker returns 1 and would size every worker's pool to the whole limit.
static WORKERS: OnceLock<usize> = OnceLock::new();

thread_local! {
    // The app factory runs once per listener on every worker, so the pool is
    // kept per thread to open the worker's share of connections only once.
    static DB: OnceCell<Option<Db>> = const { OnceCell::new() };
}

struct Conn {
    client: Client,
    query: Statement,
    fortunes: Statement,
}

#[derive(Clone)]
struct Db {
    config: Config,
    pool: Pool<Conn>,
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
/// Call it on the main thread before the server starts its workers.
pub fn set_workers(workers: usize) {
    let _ = WORKERS.set(workers.max(1));
}

/// Opens this worker's pool, unless `DATABASE_URL` is unset or invalid.
///
/// Connections are opened in the background and retried until Postgres
/// accepts them, so startup never waits on or fails because of the database.
pub fn init() {
    DB.with(|db| {
        db.get_or_init(|| {
            let config = Config::from_str(&std::env::var("DATABASE_URL").ok()?).ok()?;
            let max_conn = std::env::var("DATABASE_MAX_CONN")
                .ok()
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(256);
            // Recorded by `main`. Unpinned callers that skip it (tests) fall
            // back to the CPUs their own thread may run on.
            let workers = WORKERS
                .get()
                .copied()
                .unwrap_or_else(|| std::thread::available_parallelism().map_or(1, |n| n.get()));
            let size = (max_conn / workers).max(1);
            let db = Db {
                config,
                pool: Pool::new(size),
            };
            for _ in 0..size {
                ntex::rt::spawn(db.clone().open());
            }
            Some(db)
        });
    });
}

impl Db {
    /// Opens one connection, retrying until it succeeds, and adds it to the pool.
    async fn open(self) {
        loop {
            if let Ok(conn) = self.connect().await {
                let _ = self.pool.try_add(conn);
                return;
            }
            ntex::time::sleep(RECONNECT_DELAY).await;
        }
    }

    /// Drops a closed connection from the pool and reopens it in the background.
    fn replace(&self, conn: Object<Conn>) {
        drop(Object::take(conn));
        ntex::rt::spawn(self.clone().open());
    }

    /// Replaces every idle connection Postgres has closed. Busy ones are
    /// replaced when their query fails or at their next checkout.
    fn evict_closed(&self) {
        let mut live = Vec::new();
        while let Ok(conn) = self.pool.try_get() {
            if conn.client.is_closed() {
                self.replace(conn);
            } else {
                live.push(conn);
            }
        }
    }

    /// Runs the statement `stmt` picks from a pooled connection, or returns
    /// `None` if nothing connects within the retries, checkout times out or
    /// the query fails.
    async fn query(
        &self,
        stmt: fn(&Conn) -> &Statement,
        params: &[&(dyn ToSql + Sync)],
    ) -> Option<Vec<Row>> {
        let mut retries = NOT_CONNECTED_RETRIES;
        let conn = loop {
            // Nothing is connected: give a reconnect a moment, then fail
            // instead of waiting the full checkout timeout.
            if self.pool.status().size == 0 {
                if retries == 0 {
                    return None;
                }
                retries -= 1;
                ntex::time::sleep(NOT_CONNECTED_DELAY).await;
                continue;
            }
            let conn = ntex::time::timeout(CHECKOUT_TIMEOUT, self.pool.get())
                .await
                .ok()?
                .ok()?;
            // Skip connections Postgres has closed, e.g. after a restart.
            if !conn.client.is_closed() {
                break conn;
            }
            self.replace(conn);
        };
        match conn.client.query(stmt(&conn), params).await {
            Ok(rows) => Some(rows),
            Err(_) => {
                if conn.client.is_closed() {
                    self.replace(conn);
                }
                None
            }
        }
    }

    async fn connect(&self) -> Result<Conn, Box<dyn std::error::Error>> {
        let config = &self.config;
        let host = match config.get_hosts().first() {
            Some(Host::Tcp(host)) => host.clone(),
            None => "localhost".to_string(),
            #[cfg(unix)]
            Some(Host::Unix(_)) => return Err("unix socket hosts are not supported".into()),
        };
        let port = config.get_ports().first().copied().unwrap_or(5432);
        let io = ntex::connect::connect(ntex::connect::Connect::new(host).set_port(port)).await?;
        let (client, connection) = config.connect_raw(io, NoTls).await?;
        // The connection future drives the socket for every query on this
        // client and ends when Postgres closes it, e.g. on restart.
        let db = self.clone();
        ntex::rt::spawn(async move {
            let _ = connection.await;
            db.evict_closed();
        });
        let query = client.prepare(QUERY).await?;
        let fortunes = client.prepare(FORTUNES).await?;
        Ok(Conn {
            client,
            query,
            fortunes,
        })
    }
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

/// Parses `min`, `max` and `limit`, falling back to 10, 50 and 50 and
/// clamping `limit` to 1..=50.
fn params(query: &[(String, String)]) -> (i32, i32, i64) {
    let get = |name: &str| {
        query
            .iter()
            .find_map(|(key, value)| (key == name).then_some(value))
            .and_then(|value| value.trim().parse::<i64>().ok())
    };
    let int = |value: Option<i64>, default: i32| {
        value.and_then(|v| i32::try_from(v).ok()).unwrap_or(default)
    };
    (
        int(get("min"), 10),
        int(get("max"), 50),
        get("limit").unwrap_or(50).clamp(1, 50),
    )
}

fn current() -> Option<Db> {
    DB.with(|db| db.get().cloned().flatten())
}

/// All `fortune` rows as `(id, message)`, or `None` without a database or on
/// a database error.
pub async fn fortunes() -> Option<Vec<Row>> {
    current()?.query(|conn| &conn.fortunes, &[]).await
}

/// Items in the requested price range, or `500` without a database or on a
/// database error.
pub async fn async_db(query: web::types::Query<Vec<(String, String)>>) -> HttpResponse {
    let (min, max, limit) = params(&query);
    let rows = match current() {
        Some(db) => db.query(|conn| &conn.query, &[&min, &max, &limit]).await,
        None => None,
    };
    let Some(rows) = rows else {
        return HttpResponse::InternalServerError().build();
    };
    let items: Vec<_> = rows.iter().map(item).collect();
    HttpResponse::Ok().json(&DbList {
        count: items.len(),
        items,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ntex::http::StatusCode;
    use ntex::web::{
        App,
        test::{self, TestRequest},
    };

    fn query(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// STATEMENT: `params` applies the documented defaults and clamps `limit`.
    ///
    /// HOW:
    /// - Parse an empty query and confirm `(10, 50, 50)`.
    /// - Parse explicit values, an out-of-range `limit` both ways, and
    ///   non-numeric or `i32`-overflowing bounds, and compare each tuple.
    #[test]
    fn params_defaults_and_clamping() {
        assert_eq!(params(&[]), (10, 50, 50));
        assert_eq!(
            params(&query(&[("min", "20"), ("max", "300"), ("limit", "7")])),
            (20, 300, 7)
        );
        assert_eq!(params(&query(&[("limit", "500")])).2, 50);
        assert_eq!(params(&query(&[("limit", "0")])).2, 1);
        assert_eq!(params(&query(&[("limit", "-3")])).2, 1);
        assert_eq!(
            params(&query(&[("min", "x"), ("max", "99999999999")])),
            (10, 50, 50)
        );
    }

    async fn async_db_status() -> StatusCode {
        let app = test::init_service(
            App::new().service(web::resource("/async-db").route(web::get().to(async_db))),
        )
        .await;
        app.call(TestRequest::with_uri("/async-db?min=10&max=50&limit=5").to_request())
            .await
            .unwrap()
            .status()
    }

    /// Polls `done` every 50 ms for up to 5 seconds.
    async fn wait_for(done: impl Fn() -> bool) -> bool {
        for _ in 0..100 {
            if done() {
                return true;
            }
            ntex::time::sleep(Duration::from_millis(50)).await;
        }
        done()
    }

    /// STATEMENT: Without a database `/async-db` fails with `500`.
    ///
    /// HOW:
    /// - Call `async_db` on a thread where `init` never opened a pool.
    /// - Confirm the status is `500 Internal Server Error`.
    #[ntex::test]
    async fn error_without_database() {
        assert_eq!(async_db_status().await, StatusCode::INTERNAL_SERVER_ERROR);
    }

    /// STATEMENT: While the pool has no open connection, `/async-db` retries
    /// `NOT_CONNECTED_RETRIES` times, then fails with `500` well before the
    /// checkout timeout.
    ///
    /// HOW:
    /// - Install a `Db` with an empty pool in this thread's `DB` cell, as
    ///   `init` does before any connection opens.
    /// - Call `async_db` and confirm `500 Internal Server Error`.
    /// - Confirm the call took at least `NOT_CONNECTED_RETRIES` times
    ///   `NOT_CONNECTED_DELAY` and less than `CHECKOUT_TIMEOUT`.
    #[ntex::test]
    async fn error_while_not_connected() {
        DB.with(|db| {
            let _ = db.set(Some(Db {
                config: Config::new(),
                pool: Pool::new(1),
            }));
        });
        let start = std::time::Instant::now();
        assert_eq!(async_db_status().await, StatusCode::INTERNAL_SERVER_ERROR);
        let elapsed = start.elapsed();
        assert!(elapsed >= NOT_CONNECTED_DELAY * NOT_CONNECTED_RETRIES);
        assert!(elapsed < CHECKOUT_TIMEOUT);
    }

    /// STATEMENT: A request that arrives before the first connection opens
    /// waits for it instead of failing.
    ///
    /// HOW:
    /// - Needs Postgres at `DATABASE_URL`.
    /// - Install a `Db` with an empty pool in this thread's `DB` cell and
    ///   spawn one `Db::open`.
    /// - Call `async_db` straight away and confirm `200 OK`.
    #[ntex::test]
    #[ignore = "needs Postgres at DATABASE_URL"]
    async fn waits_for_reconnect() {
        let config = Config::from_str(&std::env::var("DATABASE_URL").unwrap()).unwrap();
        let db = Db {
            config,
            pool: Pool::new(1),
        };
        DB.with(|cell| {
            let _ = cell.set(Some(db.clone()));
        });
        ntex::rt::spawn(db.open());
        assert_eq!(async_db_status().await, StatusCode::OK);
    }

    /// STATEMENT: Connections Postgres closed are skipped and reopened, so
    /// requests keep succeeding while one live connection remains.
    ///
    /// HOW:
    /// - Needs Postgres at `DATABASE_URL`.
    /// - Call `init` and wait until the pool is full, check out every
    ///   connection and read its `pg_backend_pid()`.
    /// - From the first connection, `pg_terminate_backend` the others, wait
    ///   until their clients report closed, then return all to the pool.
    /// - Request `/async-db` once per pooled connection and confirm every
    ///   status is `200`.
    /// - Confirm the pool refills to its full size.
    #[ntex::test]
    #[ignore = "needs Postgres at DATABASE_URL"]
    async fn closed_connections_are_skipped() {
        init();
        let db = current().expect("DATABASE_URL");
        let max = db.pool.status().max_size;
        assert!(max > 1, "needs at least two connections per pool");
        assert!(wait_for(|| db.pool.status().size == max).await);

        let mut conns = Vec::new();
        let mut pids = Vec::new();
        for _ in 0..max {
            let conn = db.pool.get().await.unwrap();
            let row = conn
                .client
                .query_one("SELECT pg_backend_pid()", &[])
                .await
                .unwrap();
            pids.push(row.get::<_, i32>(0));
            conns.push(conn);
        }
        conns[0]
            .client
            .query(
                "SELECT pg_terminate_backend(pid) FROM unnest($1::int4[]) AS pid",
                &[&pids[1..].to_vec()],
            )
            .await
            .unwrap();
        assert!(wait_for(|| conns[1..].iter().all(|c| c.client.is_closed())).await);
        drop(conns);

        for _ in 0..max {
            assert_eq!(async_db_status().await, StatusCode::OK);
        }
        assert!(wait_for(|| db.pool.status().size == max).await);
    }

    /// STATEMENT: Idle connections Postgres closes are replaced without
    /// waiting for a request to find them.
    ///
    /// HOW:
    /// - Needs Postgres at `DATABASE_URL`.
    /// - Call `init` and wait until the pool is full, check out every
    ///   connection, read its `pg_backend_pid()`, then return all but the
    ///   first to the pool.
    /// - From the first connection, `pg_terminate_backend` the others.
    /// - Without sending requests, wait until the pool is full again and
    ///   every idle connection is open.
    #[ntex::test]
    #[ignore = "needs Postgres at DATABASE_URL"]
    async fn idle_closed_connections_are_replaced() {
        init();
        let db = current().expect("DATABASE_URL");
        let max = db.pool.status().max_size;
        assert!(max > 1, "needs at least two connections per pool");
        assert!(wait_for(|| db.pool.status().size == max).await);

        let mut conns = Vec::new();
        let mut pids = Vec::new();
        for _ in 0..max {
            let conn = db.pool.get().await.unwrap();
            let row = conn
                .client
                .query_one("SELECT pg_backend_pid()", &[])
                .await
                .unwrap();
            pids.push(row.get::<_, i32>(0));
            conns.push(conn);
        }
        let first = conns.remove(0);
        drop(conns);
        first
            .client
            .query(
                "SELECT pg_terminate_backend(pid) FROM unnest($1::int4[]) AS pid",
                &[&pids[1..].to_vec()],
            )
            .await
            .unwrap();
        drop(first);

        let all_idle_open = || {
            let mut idle = Vec::new();
            while let Ok(conn) = db.pool.try_get() {
                idle.push(conn);
            }
            idle.len() == max && idle.iter().all(|c| !c.client.is_closed())
        };
        assert!(wait_for(all_idle_open).await);
    }

    /// STATEMENT: Queries run against Postgres over ntex `Io` and match the
    /// expected item shape, `LIMIT` and empty-range behaviour.
    ///
    /// HOW:
    /// - Needs the HttpArena seed loaded into the Postgres at `DATABASE_URL`.
    /// - Call `init`, wait until the pool holds a connection, then request
    ///   several limits and confirm `count` equals the limit and every item
    ///   has integer prices within range, a `tags` list, a boolean `active`
    ///   and a `rating` with `score` and `count`.
    /// - Request `min=9999&max=9999` and confirm `count` is `0`.
    #[ntex::test]
    #[ignore = "needs Postgres with the HttpArena seed at DATABASE_URL"]
    async fn queries_postgres() {
        init();
        let db = current().expect("DATABASE_URL");
        for _ in 0..100 {
            if db.pool.status().size > 0 {
                break;
            }
            ntex::time::sleep(Duration::from_millis(50)).await;
        }
        let app = test::init_service(
            App::new().service(web::resource("/async-db").route(web::get().to(async_db))),
        )
        .await;

        for (min, max, limit) in [(10, 50, 1), (20, 300, 17), (1, 400, 50)] {
            let uri = format!("/async-db?min={min}&max={max}&limit={limit}");
            let response = app
                .call(TestRequest::with_uri(&uri).to_request())
                .await
                .unwrap();
            let body: serde_json::Value =
                serde_json::from_slice(&test::read_body(response).await).unwrap();
            assert_eq!(body["count"], limit);
            let items = body["items"].as_array().unwrap();
            assert_eq!(items.len(), limit as usize);
            for item in items {
                let price = item["price"].as_i64().unwrap();
                assert!((min..=max).contains(&price));
                assert!(item["id"].is_i64() && item["quantity"].is_i64());
                assert!(item["name"].is_string() && item["category"].is_string());
                assert!(item["active"].is_boolean());
                assert!(item["tags"].is_array());
                assert!(item["rating"]["score"].is_i64());
                assert!(item["rating"]["count"].is_i64());
            }
        }

        let response = app
            .call(TestRequest::with_uri("/async-db?min=9999&max=9999&limit=50").to_request())
            .await
            .unwrap();
        assert_eq!(test::read_body(response).await, r#"{"items":[],"count":0}"#);
    }
}
