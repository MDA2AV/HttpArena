//! HttpArena entry for mq-bridge (Rust).
//!
//! One catch-all `http -> response` route per listener, dispatching on the
//! request's `http_method` / `http_path` / `http_query` metadata and replying
//! through mq-bridge's inline-response fast path.
//!
//! | Endpoint | Reply | Profiles |
//! |---|---|---|
//! | `GET  /pipeline`                | `ok`                  | baseline, pipelined, limited-conn |
//! | `GET  /baseline11?a=&b=`        | `a+b`                 | baseline |
//! | `POST /baseline11?a=&b=` + body | `a+b+body`            | baseline |
//! | `GET  /baseline2?a=&b=`         | `a+b`                 | baseline-h2, baseline-h2c |
//! | `GET  /json/{count}?m=`         | processed dataset     | json, json-comp, json-tls, json-h2c |
//! | `POST /upload` + body           | byte count            | upload |
//! | `GET  /async-db?min=&max=&limit=` | `items` rows        | async-db |
//! | `GET  /static/{file}`           | cached asset          | static, static-tls, static-h2 |
//! | `GET  /crud/items?category=&page=&limit=` | paginated list | crud |
//! | `GET  /crud/items/{id}`         | cached item           | crud |
//! | `POST /crud/items` + JSON       | 201 + upserted item   | crud |
//! | `PUT  /crud/items/{id}` + JSON  | updated item          | crud |
//! | `GET  /fortunes`                | rendered HTML table   | fortunes |
//!
//! Listeners: 8080 HTTP/1.1 + h2c (auto), 8082 h2c-only, 8443 h2-over-TLS,
//! 8081 HTTP/1.1-over-TLS. TLS ports bind only when certs are mounted.
//!
//! Harness inputs: `DATASET_PATH`, `STATIC_DIR`, `DATABASE_URL`,
//! `DATABASE_MAX_CONN`. A missing database is non-fatal — the DB-backed
//! endpoints degrade rather than blocking the cleartext profiles.

use askama::Template;
use bytes::Bytes;
use dashmap::DashMap;
use mq_bridge::endpoints::http::{guess_content_type, HttpRequestExt, HTTP_STATUS_CODE};
use mq_bridge::models::{Endpoint, EndpointType, HttpConfig, HttpServerProtocol, TlsConfig};
use mq_bridge::sqlx::postgres::{PgPoolOptions, PgRow};
use mq_bridge::sqlx::types::Json;
use mq_bridge::sqlx::{self, PgPool, Row};
use mq_bridge::{CanonicalMessage, Handled, HandlerError, Route};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const SERVER: &str = "mq-bridge";

// ---------- models ----------

#[derive(Deserialize)]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize)]
struct DatasetItem {
    id: i64,
    name: String,
    category: String,
    price: i64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: Rating,
}

#[derive(Serialize)]
struct RatingOut {
    score: i64,
    count: i64,
}

#[derive(Serialize)]
struct ProcessedItem<'a> {
    id: i64,
    name: &'a str,
    category: &'a str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'a [String],
    rating: RatingOut,
    total: i64,
}

#[derive(Serialize)]
struct JsonResponse<'a> {
    items: Vec<ProcessedItem<'a>>,
    count: usize,
}

/// One `items` row, borrowed from the sqlx row buffer for the duration of the
/// response. `/async-db` and `/crud` specify the same item shape.
#[derive(Serialize)]
struct DbItem<'a> {
    id: i32,
    name: &'a str,
    category: &'a str,
    price: i32,
    quantity: i32,
    active: bool,
    tags: &'a RawValue,
    rating: RatingOut,
}

#[derive(Serialize)]
struct DbResponse<'a> {
    count: usize,
    items: Vec<DbItem<'a>>,
}

#[derive(Serialize)]
struct CrudListResponse<'a> {
    items: Vec<DbItem<'a>>,
    total: usize,
    page: i64,
    limit: i64,
}

#[derive(Deserialize)]
struct CrudCreate {
    id: i32,
    name: String,
    category: String,
    price: i32,
    quantity: i32,
}

/// Optional fields so a partial `PUT` leaves the rest of the row alone; the SQL
/// COALESCEs each bind against the current value.
#[derive(Deserialize)]
struct CrudUpdate {
    name: Option<String>,
    category: Option<String>,
    price: Option<i32>,
    quantity: Option<i32>,
}

struct AppState {
    dataset: Vec<DatasetItem>,
    static_dir: PathBuf,
    crud_cache: CrudCache,
    pool: Option<PgPool>,
}

// ---------- caches ----------

/// Cache-aside store behind `GET /crud/items/{id}`, holding the rendered body
/// so a hit skips both the query and the serialization.
///
/// Expiry is lazy and absolute: an entry is tested only when read, and the next
/// miss overwrites it. Nothing sweeps or refreshes in the background — which is
/// what the profile asks for — and the key space is bounded by the id range.
#[derive(Default)]
struct CrudCache {
    entries: DashMap<i32, (Instant, Bytes)>,
}

const CRUD_TTL: Duration = Duration::from_secs(1);

impl CrudCache {
    fn get(&self, id: i32) -> Option<Bytes> {
        let entry = self.entries.get(&id)?;
        let (stored_at, body) = entry.value();
        (stored_at.elapsed() < CRUD_TTL).then(|| body.clone())
    }

    fn put(&self, id: i32, body: Bytes) {
        self.entries.insert(id, (Instant::now(), body));
    }

    fn invalidate(&self, id: i32) {
        self.entries.remove(&id);
    }
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

// ---------- replies ----------

fn reply_bytes(body: Bytes, content_type: &str) -> CanonicalMessage {
    CanonicalMessage::new_bytes(body, None)
        .with_metadata_kv("content-type", content_type)
        .with_metadata_kv("Server", SERVER)
}

fn text(body: String) -> CanonicalMessage {
    reply_bytes(Bytes::from(body), "text/plain")
}

fn json(body: Vec<u8>) -> CanonicalMessage {
    reply_bytes(Bytes::from(body), "application/json")
}

fn status(code: u16, body: &str) -> CanonicalMessage {
    text(body.to_string()).with_metadata_kv(HTTP_STATUS_CODE, code.to_string())
}

fn unavailable() -> CanonicalMessage {
    status(503, "Service Unavailable")
}

fn not_found() -> CanonicalMessage {
    status(404, "Not Found")
}

// ---------- json profile ----------

/// Serialized fresh per request — no response caching. The library compresses
/// it per request when the client advertises an encoding (see `make_http`), so
/// `json` and `json-comp` measure real serialization and compression work.
fn serve_json(state: &AppState, count: usize, m: i64) -> CanonicalMessage {
    let count = count.min(state.dataset.len());
    let items: Vec<ProcessedItem> = state.dataset[..count]
        .iter()
        .map(|d| ProcessedItem {
            id: d.id,
            name: &d.name,
            category: &d.category,
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: &d.tags,
            rating: RatingOut {
                score: d.rating.score,
                count: d.rating.count,
            },
            total: d.price * d.quantity * m,
        })
        .collect();
    json(serde_json::to_vec(&JsonResponse { count, items }).unwrap_or_default())
}

// ---------- database ----------

macro_rules! item_cols {
    () => {
        "id, name, category, price, quantity, active, tags, rating_score, rating_count"
    };
}

/// Borrows straight into the serializer: no `serde_json::Value` tree, and
/// `tags` (jsonb) is re-emitted verbatim instead of being parsed into a
/// `Vec<String>` and re-serialized. Positional access skips sqlx's per-field
/// name lookup; every query below selects `item_cols!()` in this order.
fn row_to_item(row: &PgRow) -> DbItem<'_> {
    DbItem {
        id: row.get(0),
        name: row.get(1),
        category: row.get(2),
        price: row.get(3),
        quantity: row.get(4),
        active: row.get(5),
        tags: row.get::<Json<&RawValue>, _>(6).0,
        rating: RatingOut {
            score: row.get::<i32, _>(7) as i64,
            count: row.get::<i32, _>(8) as i64,
        },
    }
}

async fn async_db(state: &AppState, msg: &CanonicalMessage) -> CanonicalMessage {
    const SQL: &str = concat!(
        "SELECT ",
        item_cols!(),
        " FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"
    );
    const EMPTY: &[u8] = br#"{"items":[],"count":0}"#;

    let Some(pool) = state.pool.as_ref() else {
        return json(EMPTY.to_vec());
    };
    let rows = sqlx::query(SQL)
        .bind(msg.query_int("min").unwrap_or(10) as i32)
        .bind(msg.query_int("max").unwrap_or(50) as i32)
        .bind(msg.query_int("limit").unwrap_or(50).clamp(1, 50))
        .fetch_all(pool)
        .await;
    let Ok(rows) = rows else {
        return json(EMPTY.to_vec());
    };

    let items: Vec<DbItem> = rows.iter().map(row_to_item).collect();
    json(
        serde_json::to_vec(&DbResponse {
            count: items.len(),
            items,
        })
        .unwrap_or_default(),
    )
}

// ---------- crud profile ----------
//
// The harness also offers a Redis sidecar, but that is for multi-process
// runtimes; this server is one tokio runtime sharing a heap, so the cache-aside
// above is in-process.

const CRUD_ITEM: &str = "/crud/items/";

fn crud_id(path: &str) -> Option<i32> {
    path[CRUD_ITEM.len()..].parse().ok()
}

/// One query, no `SELECT COUNT(*)`: `total` reports the rows in this response,
/// which is what the profile asks for — the full-filter count was dropped from
/// the spec because it dominated Postgres CPU under concurrent writes.
async fn crud_list(state: &AppState, msg: &CanonicalMessage) -> CanonicalMessage {
    const SQL: &str = concat!(
        "SELECT ",
        item_cols!(),
        " FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3"
    );

    let Some(pool) = state.pool.as_ref() else {
        return unavailable();
    };
    let page = msg.query_int("page").unwrap_or(1).max(1);
    let limit = msg.query_int("limit").unwrap_or(10).clamp(1, 50);
    let rows = match sqlx::query(SQL)
        .bind(msg.query_param("category").unwrap_or("electronics"))
        .bind(limit as i32)
        .bind(((page - 1) * limit) as i32)
        .fetch_all(pool)
        .await
    {
        Ok(rows) => rows,
        Err(_) => return status(500, "Internal Server Error"),
    };

    let items: Vec<DbItem> = rows.iter().map(row_to_item).collect();
    json(
        serde_json::to_vec(&CrudListResponse {
            total: items.len(),
            items,
            page,
            limit,
        })
        .unwrap_or_default(),
    )
}

async fn crud_get(state: &AppState, id: i32) -> CanonicalMessage {
    const SQL: &str = concat!("SELECT ", item_cols!(), " FROM items WHERE id = $1");

    if let Some(body) = state.crud_cache.get(id) {
        return reply_bytes(body, "application/json").with_metadata_kv("X-Cache", "HIT");
    }
    let Some(pool) = state.pool.as_ref() else {
        return unavailable();
    };
    let row = match sqlx::query(SQL).bind(id).fetch_optional(pool).await {
        Ok(Some(row)) => row,
        Ok(None) => return not_found(),
        Err(_) => return status(500, "Internal Server Error"),
    };
    let body = Bytes::from(serde_json::to_vec(&row_to_item(&row)).unwrap_or_default());
    state.crud_cache.put(id, body.clone());
    reply_bytes(body, "application/json").with_metadata_kv("X-Cache", "MISS")
}

/// `active` / `tags` / `rating_*` are NOT NULL with no default and the create
/// body carries none of them, so a new row seeds them; a conflict updates only
/// the four fields the body actually sends.
async fn crud_create(state: &AppState, payload: &[u8]) -> CanonicalMessage {
    const SQL: &str = concat!(
        "INSERT INTO items (",
        item_cols!(),
        ") \
         VALUES ($1, $2, $3, $4, $5, true, '[]'::jsonb, 0, 0) \
         ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, \
         price = EXCLUDED.price, quantity = EXCLUDED.quantity RETURNING ",
        item_cols!()
    );

    let Some(pool) = state.pool.as_ref() else {
        return unavailable();
    };
    let Ok(item) = serde_json::from_slice::<CrudCreate>(payload) else {
        return status(400, "Bad Request");
    };
    let row = sqlx::query(SQL)
        .bind(item.id)
        .bind(&item.name)
        .bind(&item.category)
        .bind(item.price)
        .bind(item.quantity)
        .fetch_one(pool)
        .await;
    match row {
        Ok(row) => {
            // The upsert may have replaced a row someone already read.
            state.crud_cache.invalidate(item.id);
            json(serde_json::to_vec(&row_to_item(&row)).unwrap_or_default())
                .with_metadata_kv(HTTP_STATUS_CODE, "201")
        }
        Err(_) => status(500, "Internal Server Error"),
    }
}

async fn crud_update(state: &AppState, id: i32, payload: &[u8]) -> CanonicalMessage {
    const SQL: &str = concat!(
        "UPDATE items SET name = COALESCE($2, name), category = COALESCE($3, category), \
         price = COALESCE($4, price), quantity = COALESCE($5, quantity) \
         WHERE id = $1 RETURNING ",
        item_cols!()
    );

    let Some(pool) = state.pool.as_ref() else {
        return unavailable();
    };
    let Ok(update) = serde_json::from_slice::<CrudUpdate>(payload) else {
        return status(400, "Bad Request");
    };
    let row = sqlx::query(SQL)
        .bind(id)
        .bind(update.name.as_deref())
        .bind(update.category.as_deref())
        .bind(update.price)
        .bind(update.quantity)
        .fetch_optional(pool)
        .await;
    match row {
        Ok(Some(row)) => {
            state.crud_cache.invalidate(id);
            json(serde_json::to_vec(&row_to_item(&row)).unwrap_or_default())
        }
        Ok(None) => not_found(),
        Err(_) => status(500, "Internal Server Error"),
    }
}

// ---------- fortunes profile ----------

/// Named-entity HTML escaper, selected for `.html` templates by `askama.toml`.
///
/// Askama's built-in escaper emits numeric entities (`&#60;`), but the profile's
/// validator greps the body for the literal `&lt;script&gt;`, so correctly
/// escaped output would still be rejected.
#[derive(Copy, Clone)]
pub struct NamedHtmlEscaper;

impl askama::filters::Escaper for NamedHtmlEscaper {
    fn write_escaped_str<W: std::fmt::Write>(&self, mut dest: W, s: &str) -> std::fmt::Result {
        let mut last = 0;
        for (i, b) in s.bytes().enumerate() {
            let replacement = match b {
                b'<' => "&lt;",
                b'>' => "&gt;",
                b'&' => "&amp;",
                b'"' => "&quot;",
                b'\'' => "&#39;",
                _ => continue,
            };
            dest.write_str(&s[last..i])?;
            dest.write_str(replacement)?;
            last = i + 1;
        }
        dest.write_str(&s[last..])
    }
}

/// Borrowed from the sqlx rows, so rendering 201 rows allocates the page and
/// nothing else. The runtime row's `&'static str` coerces into the same slot.
struct Fortune<'a> {
    id: i32,
    message: &'a str,
}

#[derive(Template)]
#[template(path = "fortunes.html")]
struct FortunesTemplate<'a> {
    fortunes: Vec<Fortune<'a>>,
}

/// Query, append the runtime row in memory, sort by ordinal byte order (never
/// locale-aware — that reorders per runtime), then render per request.
async fn fortunes(state: &AppState) -> CanonicalMessage {
    let Some(pool) = state.pool.as_ref() else {
        return unavailable();
    };
    let Ok(rows) = sqlx::query("SELECT id, message FROM fortune")
        .fetch_all(pool)
        .await
    else {
        return status(500, "Internal Server Error");
    };

    let mut fortunes: Vec<Fortune> = rows
        .iter()
        .map(|row| Fortune {
            id: row.get(0),
            message: row.get(1),
        })
        .collect();
    fortunes.push(Fortune {
        id: 0,
        message: "Additional fortune added at request time.",
    });
    fortunes.sort_by(|a, b| a.message.as_bytes().cmp(b.message.as_bytes()));

    match (FortunesTemplate { fortunes }).render() {
        Ok(html) => reply_bytes(Bytes::from(html), "text/html; charset=utf-8"),
        Err(_) => status(500, "Internal Server Error"),
    }
}

// ---------- static ----------

async fn serve_static(state: &AppState, name: &str, want_gzip: bool) -> CanonicalMessage {
    // Reject traversal: the filename must be a single normal component.
    let mut comps = Path::new(name).components();
    let safe = matches!(comps.next(), Some(Component::Normal(_))) && comps.next().is_none();
    if !safe {
        return not_found();
    }
    let path = state.static_dir.join(name);
    let content_type = guess_content_type(name);
    if want_gzip {
        let mut gzip_path = path.as_os_str().to_os_string();
        gzip_path.push(".gz");
        if let Ok(bytes) = tokio::fs::read(gzip_path).await {
            return reply_bytes(Bytes::from(bytes), content_type)
                .with_metadata_kv("content-encoding", "gzip");
        }
    }
    match tokio::fs::read(path).await {
        Ok(bytes) => reply_bytes(Bytes::from(bytes), content_type),
        Err(_) => not_found(),
    }
}

// ---------- dispatch ----------

async fn handle(state: Arc<AppState>, msg: CanonicalMessage) -> Result<Handled, HandlerError> {
    let out = match (msg.http_method(), msg.http_path()) {
        ("GET", "/pipeline") => text("ok".to_string()),
        ("GET", "/baseline11") | ("GET", "/baseline2") => {
            text((msg.query_int("a").unwrap_or(0) + msg.query_int("b").unwrap_or(0)).to_string())
        }
        ("POST", "/baseline11") => {
            let body = std::str::from_utf8(&msg.payload)
                .ok()
                .and_then(|s| s.trim().parse::<i64>().ok())
                .unwrap_or(0);
            let sum = msg.query_int("a").unwrap_or(0) + msg.query_int("b").unwrap_or(0) + body;
            text(sum.to_string())
        }
        ("POST", "/upload") => text(msg.payload.len().to_string()),
        ("GET", "/async-db") => async_db(&state, &msg).await,
        ("GET", "/fortunes") => fortunes(&state).await,
        ("GET", "/crud/items") => crud_list(&state, &msg).await,
        ("POST", "/crud/items") => crud_create(&state, &msg.payload).await,
        ("GET", p) if p.starts_with(CRUD_ITEM) => match crud_id(p) {
            Some(id) => crud_get(&state, id).await,
            None => not_found(),
        },
        ("PUT", p) if p.starts_with(CRUD_ITEM) => match crud_id(p) {
            Some(id) => crud_update(&state, id, &msg.payload).await,
            None => not_found(),
        },
        ("GET", p) if p.starts_with("/json/") => {
            let count = p["/json/".len()..].parse().unwrap_or(0);
            serve_json(&state, count, msg.query_int("m").unwrap_or(1))
        }
        ("GET", p) if p.starts_with("/static/") => {
            serve_static(&state, &p["/static/".len()..], msg.accepts_gzip()).await
        }
        _ => not_found(),
    };
    Ok(Handled::Publish(out))
}

// ---------- setup ----------

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let state = Arc::new(AppState {
        dataset: load_dataset(),
        static_dir: PathBuf::from(
            std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".to_string()),
        ),
        crud_cache: CrudCache::default(),
        pool: connect_pool().await,
    });

    let listen = env_addr("MQB_LISTEN", 8080);
    let mut handles = vec![
        route(make_http(listen, None), &state)
            .run("httparena")
            .await?,
    ];

    // `Http2Only` makes 8082 refuse HTTP/1.1, satisfying the h2c-only
    // anti-cheat — a dual-serving port is rejected.
    let h2c = make_http(env_addr("MQB_H2C_LISTEN", 8082), None)
        .with_server_protocol(HttpServerProtocol::Http2Only);
    handles.push(route(h2c, &state).run("httparena-h2c").await?);

    if let Some(tls) = tls_config() {
        let h2 = make_http(env_addr("MQB_TLS_LISTEN", 8443), Some(tls.clone()));
        handles.push(route(h2, &state).run("httparena-tls").await?);

        // ALPN `http/1.1` only, so the json-tls load generator negotiates
        // HTTP/1.1 rather than upgrading to h2.
        let h1 = make_http(env_addr("MQB_H1TLS_LISTEN", 8081), Some(tls))
            .with_server_protocol(HttpServerProtocol::Http1Only);
        handles.push(route(h1, &state).run("httparena-json-tls").await?);
    }

    for handle in handles {
        handle.join().await?;
    }
    Ok(())
}

fn env_addr(var: &str, default_port: u16) -> String {
    std::env::var(var).unwrap_or_else(|_| format!("0.0.0.0:{default_port}"))
}

/// Pool size comes from `DATABASE_MAX_CONN`, as the async-db profile requires.
/// A failure is logged, not fatal: the DB-backed endpoints then degrade.
async fn connect_pool() -> Option<PgPool> {
    let url = std::env::var("DATABASE_URL")
        .ok()
        .filter(|u| !u.is_empty())?;
    let max = std::env::var("DATABASE_MAX_CONN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(256);
    match PgPoolOptions::new()
        .max_connections(max)
        .connect(&url)
        .await
    {
        Ok(pool) => Some(pool),
        Err(e) => {
            eprintln!("Postgres connection failed ({e}); DB endpoints degrade");
            None
        }
    }
}

/// `None` (and a log) when certs aren't mounted, so a plaintext-only run works.
fn tls_config() -> Option<TlsConfig> {
    let cert = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    if !Path::new(&cert).is_file() || !Path::new(&key).is_file() {
        eprintln!("TLS certs not found ({cert} / {key}); serving plaintext only");
        return None;
    }
    // rustls needs a process-default crypto provider before any TLS endpoint.
    if let Err(provider) = rustls::crypto::ring::default_provider().install_default() {
        eprintln!("rustls ring provider not installed; a default is already set ({provider:?})");
    }
    let mut tls = TlsConfig::new();
    tls.required = true;
    tls.cert_file = Some(cert);
    tls.key_file = Some(key);
    Some(tls)
}

fn make_http(listen: String, tls: Option<TlsConfig>) -> HttpConfig {
    let mut http = HttpConfig::new(listen).with_inline_response_fast_path(true);
    http.concurrency_limit = Some(65_536);
    http.internal_buffer_size = Some(16_384);
    // The library negotiates the codec per request (zstd > gzip > lz4), so zstd
    // is used whenever a client offers it. The HttpArena generators send only
    // `Accept-Encoding: gzip, br`, so the measured path here is gzip.
    http.compression_enabled = Some(true);
    http.compression_threshold_bytes = Some(256);
    if let Some(tls) = tls {
        http.tls = tls;
    }
    http
}

fn route(http: HttpConfig, state: &Arc<AppState>) -> Route {
    let state = state.clone();
    Route::new(
        Endpoint::new(EndpointType::Http(http)),
        Endpoint::new_response(),
    )
    .with_handler(move |msg| handle(state.clone(), msg))
}
