//! `/async-db` and the `/fortunes` query: tokio-postgres driven over ntex
//! `Io` (through ntex-io's tokio `AsyncRead`/`AsyncWrite` impls) on the native
//! runtime, pooled per worker with deadpool's unmanaged pool.

use std::{cell::OnceCell, str::FromStr, time::Duration};

use deadpool::unmanaged::{Object, Pool};
use ntex::web::{self, HttpResponse};
use serde::Serialize;
use tokio_postgres::{Client, Config, NoTls, Row, Statement, config::Host, types::ToSql};

const QUERY: &str = "SELECT id, name, category, price, quantity, active, tags, rating_score, \
                     rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";
const FORTUNES: &str = "SELECT id, message FROM fortune";
const RECONNECT_DELAY: Duration = Duration::from_secs(1);
const CHECKOUT_TIMEOUT: Duration = Duration::from_secs(5);

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
            // ntex starts one worker per logical CPU by default.
            let workers = std::thread::available_parallelism().map_or(1, |n| n.get());
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
            if let Ok(conn) = connect(&self.config).await {
                let _ = self.pool.try_add(conn);
                return;
            }
            ntex::time::sleep(RECONNECT_DELAY).await;
        }
    }

    /// Runs the statement `stmt` picks from a pooled connection.
    async fn query(
        &self,
        stmt: fn(&Conn) -> &Statement,
        params: &[&(dyn ToSql + Sync)],
    ) -> Option<Vec<Row>> {
        // Nothing is connected yet: answer with the fallback instead of waiting.
        if self.pool.status().size == 0 {
            return None;
        }
        let conn = ntex::time::timeout(CHECKOUT_TIMEOUT, self.pool.get())
            .await
            .ok()?
            .ok()?;
        match conn.client.query(stmt(&conn), params).await {
            Ok(rows) => Some(rows),
            Err(_) => {
                if conn.client.is_closed() {
                    drop(Object::take(conn));
                    ntex::rt::spawn(self.clone().open());
                }
                None
            }
        }
    }
}

async fn connect(config: &Config) -> Result<Conn, Box<dyn std::error::Error>> {
    let host = match config.get_hosts().first() {
        Some(Host::Tcp(host)) => host.clone(),
        None => "localhost".to_string(),
        #[cfg(unix)]
        Some(Host::Unix(_)) => return Err("unix socket hosts are not supported".into()),
    };
    let port = config.get_ports().first().copied().unwrap_or(5432);
    let io = ntex::connect::connect(ntex::connect::Connect::new(host).set_port(port)).await?;
    let (client, connection) = config.connect_raw(io, NoTls).await?;
    // The connection future drives the socket for every query on this client.
    ntex::rt::spawn(connection);
    let query = client.prepare(QUERY).await?;
    let fortunes = client.prepare(FORTUNES).await?;
    Ok(Conn {
        client,
        query,
        fortunes,
    })
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

/// All `fortune` rows as `(id, message)`, or `None` without a database.
pub async fn fortunes() -> Option<Vec<Row>> {
    current()?.query(|conn| &conn.fortunes, &[]).await
}

pub async fn async_db(query: web::types::Query<Vec<(String, String)>>) -> HttpResponse {
    let (min, max, limit) = params(&query);
    let rows = match current() {
        Some(db) => db
            .query(|conn| &conn.query, &[&min, &max, &limit])
            .await
            .unwrap_or_default(),
        None => Vec::new(),
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

    /// STATEMENT: Without a database `/async-db` answers with the empty fallback.
    ///
    /// HOW:
    /// - Call `async_db` on a thread where `init` never opened a pool.
    /// - Confirm `200`, `Content-Type: application/json` and the body
    ///   `{"items":[],"count":0}`.
    #[ntex::test]
    async fn fallback_without_database() {
        let app = test::init_service(
            App::new().service(web::resource("/async-db").route(web::get().to(async_db))),
        )
        .await;
        let response = app
            .call(TestRequest::with_uri("/async-db?min=10&max=50&limit=5").to_request())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get("Content-Type").unwrap(),
            "application/json"
        );
        assert_eq!(test::read_body(response).await, r#"{"items":[],"count":0}"#);
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
