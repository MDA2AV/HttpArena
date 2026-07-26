//! HttpArena core server for mq-bridge (Rust).
//!
//! Serves the HTTP/1.1 + cleartext-HTTP/2 (h2c) profiles on `0.0.0.0:8080`
//! through a single catch-all `http -> response` route that dispatches on the
//! request's `http_method` / `http_path` / `http_query` metadata. hyper-util's
//! auto connection builder (used by mq-bridge's HTTP server) negotiates both
//! HTTP/1.1 and HTTP/2 prior-knowledge on the plaintext port, so one binary
//! covers the cleartext profiles.
//!
//! Endpoints (per HttpArena's reference contract)
//! ----------------------------------------------
//! * `GET  /pipeline`                     -> `ok`               (baseline/pipelined/limited-conn)
//! * `GET  /baseline11?a=&b=`             -> `a+b`              (baseline)
//! * `POST /baseline11?a=&b=` + body int  -> `a+b+body`
//! * `GET  /baseline2?a=&b=`              -> `a+b`                     (baseline-h2/-h2c)
//! * `GET  /json/{count}?m=`              -> processed dataset JSON   (json/json-comp/json-tls/json-h2c)
//! * `POST /upload` + body                -> received byte count      (upload)
//! * `GET  /async-db?min=&max=&limit=`    -> Postgres `items` rows    (async-db)
//! * `GET  /static/{file}`                -> file from /data/static   (static)
//!
//! Harness-provided inputs: the dataset is read from `/data/dataset.json`
//! (`DATASET_PATH` overrides), static assets from `/data/static`
//! (`STATIC_DIR`), and Postgres from `DATABASE_URL`. Missing DB is non-fatal:
//! `/async-db` then returns an empty result so the cleartext profiles still run.
//!
//! `json-comp` is handled by mq-bridge's response compression
//! (`compression_enabled`): bodies above the threshold are gzip-encoded when the
//! client advertises `Accept-Encoding: gzip`, and sent identity otherwise — so
//! the same `/json` handler serves both the `json` and `json-comp` profiles.
//!
//! `json-tls` reuses that same `/json` handler over HTTP/1.1 + TLS on `8081`
//! (ALPN `http/1.1` only), alongside the HTTP/2-over-TLS listener on `8443`. A
//! cleartext HTTP/2-only (`h2c`) listener on `8082` serves the `baseline-h2c` and
//! `json-h2c` profiles from the same handlers.

use bytes::Bytes;
use mq_bridge::endpoints::http::{guess_content_type, HttpRequestExt, HTTP_STATUS_CODE};
use mq_bridge::models::{Endpoint, EndpointType, HttpConfig, HttpServerProtocol, TlsConfig};
use mq_bridge::{CanonicalMessage, Handled, HandlerError, Route};
use serde::{Deserialize, Serialize};
use sqlx::postgres::PgPoolOptions;
use sqlx::{PgPool, Row};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

const SERVER: &str = "mq-bridge";

// ---------- dataset (json profile) ----------

#[derive(Deserialize, Clone)]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize, Clone)]
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
struct RatingOut {
    score: i64,
    count: i64,
}

#[derive(Serialize)]
struct JsonResponse<'a> {
    items: Vec<ProcessedItem<'a>>,
    count: usize,
}

struct AppState {
    dataset: Vec<DatasetItem>,
    /// Static assets read once at startup, with a pre-gzipped variant ready to
    /// serve — no per-request filesystem read or allocation.
    static_cache: HashMap<String, CachedBody>,
    pool: Option<PgPool>,
}

/// A response body cached in both identity and gzip form. The gzip variant is
/// only kept when it actually shrinks the body.
struct CachedBody {
    plain: Bytes,
    gzip: Option<Bytes>,
    content_type: &'static str,
}

impl CachedBody {
    fn build(bytes: Vec<u8>, content_type: &'static str) -> Self {
        let plain = Bytes::from(bytes);
        let compressed = gzip(&plain);
        let gzip = (compressed.len() < plain.len()).then_some(compressed);
        Self {
            plain,
            gzip,
            content_type,
        }
    }

    /// Build a reply, serving the pre-gzipped variant when the client accepts it.
    /// `content-encoding: gzip` is set on the reply; the mq-bridge HTTP layer
    /// honors it and skips its own compression pass.
    fn into_message(&self, want_gzip: bool) -> CanonicalMessage {
        let (body, encoding) = match (want_gzip, &self.gzip) {
            (true, Some(g)) => (g.clone(), Some("gzip")),
            _ => (self.plain.clone(), None),
        };
        let mut msg = CanonicalMessage::new_bytes(body, None)
            .with_metadata_kv("content-type", self.content_type)
            .with_metadata_kv("Server", SERVER);
        if let Some(encoding) = encoding {
            msg = msg.with_metadata_kv("content-encoding", encoding);
        }
        msg
    }
}

fn gzip(data: &[u8]) -> Bytes {
    use flate2::{write::GzEncoder, Compression};
    use std::io::Write;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(data).expect("gzip write");
    Bytes::from(encoder.finish().expect("gzip finish"))
}

fn load_static(dir: &Path) -> HashMap<String, CachedBody> {
    let mut cache = HashMap::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return cache;
    };
    for entry in entries.flatten() {
        if entry.file_type().map(|ft| !ft.is_file()).unwrap_or(true) {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Ok(bytes) = std::fs::read(entry.path()) {
            let content_type = guess_content_type(&name);
            cache.insert(name, CachedBody::build(bytes, content_type));
        }
    }
    cache
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

// ---------- helpers ----------

fn reply(body: Vec<u8>, content_type: &str) -> CanonicalMessage {
    CanonicalMessage::new(body, None)
        .with_metadata_kv("content-type", content_type)
        .with_metadata_kv("Server", SERVER)
}

fn text(body: String) -> CanonicalMessage {
    reply(body.into_bytes(), "text/plain")
}

fn json(body: Vec<u8>) -> CanonicalMessage {
    reply(body, "application/json")
}

fn status(status: u16, body: &str) -> CanonicalMessage {
    text(body.to_string()).with_metadata_kv(HTTP_STATUS_CODE, status.to_string())
}

// ---------- handlers ----------

fn build_json(dataset: &[DatasetItem], count: usize, m: i64) -> Vec<u8> {
    let count = count.min(dataset.len());
    let items: Vec<ProcessedItem> = dataset[..count]
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
    serde_json::to_vec(&JsonResponse { count, items }).unwrap_or_default()
}

async fn async_db(pool: &PgPool, msg: &CanonicalMessage) -> CanonicalMessage {
    let min = msg.query_int("min").unwrap_or(10) as i32;
    let max = msg.query_int("max").unwrap_or(50) as i32;
    let limit = msg.query_int("limit").unwrap_or(50).clamp(1, 50);

    let rows = sqlx::query(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
         FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
    )
    .bind(min)
    .bind(max)
    .bind(limit)
    .fetch_all(pool)
    .await;

    let rows = match rows {
        Ok(r) => r,
        Err(_) => return json(br#"{"items":[],"count":0}"#.to_vec()),
    };

    let items: Vec<serde_json::Value> = rows
        .iter()
        .map(|row| {
            // Positional column access (by SELECT order) avoids sqlx's per-field
            // name->ordinal lookup; columns match the query above.
            serde_json::json!({
                "id": row.get::<i32, _>(0),
                "name": row.get::<&str, _>(1),
                "category": row.get::<&str, _>(2),
                "price": row.get::<i32, _>(3),
                "quantity": row.get::<i32, _>(4),
                "active": row.get::<bool, _>(5),
                "tags": row.get::<serde_json::Value, _>(6),
                "rating": {
                    "score": row.get::<i32, _>(7),
                    "count": row.get::<i32, _>(8),
                }
            })
        })
        .collect();
    let body = serde_json::json!({ "count": items.len(), "items": items });
    json(serde_json::to_vec(&body).unwrap_or_default())
}

fn serve_static(state: &AppState, name: &str, want_gzip: bool) -> CanonicalMessage {
    // Reject path traversal: the filename must be a single normal component.
    let candidate = Path::new(name);
    let mut comps = candidate.components();
    let safe = matches!(comps.next(), Some(Component::Normal(_))) && comps.next().is_none();
    if !safe || name.is_empty() {
        return status(404, "Not Found");
    }
    match state.static_cache.get(name) {
        Some(cached) => cached.into_message(want_gzip),
        None => status(404, "Not Found"),
    }
}

/// Serve `/json/{count}?m=`, serializing the body fresh on every request (no
/// response caching). The library compresses it per request when the client
/// advertises `Accept-Encoding: gzip` (see `make_http`), so `json` and
/// `json-comp` measure real serialization + compression work.
fn serve_json(state: &AppState, count: usize, m: i64) -> CanonicalMessage {
    json(build_json(&state.dataset, count, m))
}

async fn handle(state: Arc<AppState>, msg: CanonicalMessage) -> Result<Handled, HandlerError> {
    let want_gzip = msg.accepts_gzip();

    let out = match (msg.http_method(), msg.http_path()) {
        ("GET", "/pipeline") => text("ok".to_string()),
        ("GET", "/baseline11") | ("GET", "/baseline2") => {
            let sum = msg.query_int("a").unwrap_or(0) + msg.query_int("b").unwrap_or(0);
            text(sum.to_string())
        }
        ("POST", "/baseline11") => {
            let mut sum = msg.query_int("a").unwrap_or(0) + msg.query_int("b").unwrap_or(0);
            if let Ok(s) = std::str::from_utf8(&msg.payload) {
                if let Ok(n) = s.trim().parse::<i64>() {
                    sum += n;
                }
            }
            text(sum.to_string())
        }
        ("POST", "/upload") => text(msg.payload.len().to_string()),
        ("GET", "/async-db") => match &state.pool {
            Some(pool) => async_db(pool, &msg).await,
            None => json(br#"{"items":[],"count":0}"#.to_vec()),
        },
        ("GET", p) if p.starts_with("/json/") => {
            let count: usize = p["/json/".len()..].parse().unwrap_or(0);
            let m = msg.query_int("m").unwrap_or(1);
            serve_json(&state, count, m)
        }
        ("GET", p) if p.starts_with("/static/") => {
            serve_static(&state, &p["/static/".len()..], want_gzip)
        }
        _ => status(404, "Not Found"),
    };

    Ok(Handled::Publish(out))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let listen = std::env::var("MQB_LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".to_string());

    let pool = match std::env::var("DATABASE_URL") {
        Ok(url) if !url.is_empty() => {
            let max = std::env::var("DATABASE_MAX_CONN")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(256);
            match PgPoolOptions::new().max_connections(max).connect(&url).await {
                Ok(pool) => Some(pool),
                Err(e) => {
                    eprintln!("Postgres connection failed ({e}); /async-db returns empty");
                    None
                }
            }
        }
        _ => None,
    };

    let state = Arc::new(AppState {
        dataset: load_dataset(),
        static_cache: load_static(&PathBuf::from(static_dir)),
        pool,
    });

    // Plaintext HTTP/1.1 + h2c on 8080.
    let plaintext = build_route(make_http(listen, None), state.clone());
    let mut handles = vec![plaintext.run("httparena").await?];

    // HTTP/2 cleartext (prior-knowledge) on 8082 (baseline-h2c / json-h2c), using
    // the same `/baseline2` and `/json` handlers. `Http2Only` makes the port
    // refuse HTTP/1.1, satisfying the h2c-only anti-cheat (a dual-serving port is
    // rejected). Cleartext, so no certs are needed.
    let h2c_listen = std::env::var("MQB_H2C_LISTEN").unwrap_or_else(|_| "0.0.0.0:8082".to_string());
    let h2c = make_http(h2c_listen, None).with_server_protocol(HttpServerProtocol::Http2Only);
    handles.push(build_route(h2c, state.clone()).run("httparena-h2c").await?);

    // TLS listeners, only when the harness has mounted certs — a local
    // plaintext-only run still works.
    if let Some(tls) = tls_config() {
        // HTTP/2 over TLS on 8443 (baseline-h2 / static-h2): ALPN advertises `h2`.
        let tls_listen =
            std::env::var("MQB_TLS_LISTEN").unwrap_or_else(|_| "0.0.0.0:8443".to_string());
        let tls_route = build_route(make_http(tls_listen, Some(tls.clone())), state.clone());
        handles.push(tls_route.run("httparena-tls").await?);

        // JSON over HTTP/1.1 + TLS on 8081 (json-tls): the same `/json` handler,
        // but the port advertises ALPN `http/1.1` only so the wrk load generator
        // negotiates HTTP/1.1 rather than upgrading to h2.
        let h1tls_listen =
            std::env::var("MQB_H1TLS_LISTEN").unwrap_or_else(|_| "0.0.0.0:8081".to_string());
        let h1tls = make_http(h1tls_listen, Some(tls))
            .with_server_protocol(HttpServerProtocol::Http1Only);
        let h1tls_route = build_route(h1tls, state.clone());
        handles.push(h1tls_route.run("httparena-json-tls").await?);
    }

    for handle in handles {
        handle.join().await?;
    }
    Ok(())
}

/// Build the TLS config for the 8443 listener from `TLS_CERT` / `TLS_KEY`,
/// installing the process-default rustls crypto provider as a side effect.
/// Returns `None` (and logs) when the certs aren't present, so plaintext-only
/// runs are unaffected.
fn tls_config() -> Option<TlsConfig> {
    let cert = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    if !Path::new(&cert).is_file() || !Path::new(&key).is_file() {
        eprintln!("TLS certs not found ({cert} / {key}); serving plaintext only");
        return None;
    }
    // rustls needs a process-default crypto provider before any TLS endpoint.
    if let Err(provider) = rustls::crypto::ring::default_provider().install_default() {
        eprintln!(
            "rustls ring crypto provider was not installed; a process default is already set (attempted provider: {provider:?})"
        );
    }
    let mut tls = TlsConfig::new();
    tls.required = true;
    tls.cert_file = Some(cert);
    tls.key_file = Some(key);
    Some(tls)
}

/// Shared HTTP listener config; `tls` set => HTTPS (ALPN h2) on the TLS port.
fn make_http(listen: String, tls: Option<TlsConfig>) -> HttpConfig {
    let mut http = HttpConfig::new(listen).with_inline_response_fast_path(true);
    http.concurrency_limit = Some(65_536);
    http.internal_buffer_size = Some(16_384);
    // Static assets are pre-gzipped once at startup (see CachedBody) and the reply
    // carries `content-encoding: gzip` when the client accepts it — the library
    // honors that and skips re-compressing them. Dynamic `/json` responses are
    // serialized fresh per request (no response caching) and compressed by the
    // library's per-request gzip when the client advertises Accept-Encoding.
    http.compression_enabled = true;
    http.compression_threshold_bytes = Some(256);
    if let Some(tls) = tls {
        http.tls = tls;
    }
    http
}

/// Builds the catch-all `http -> response` route bound to `http`, dispatching
/// every request through the shared `AppState` handler.
fn build_route(http: HttpConfig, state: Arc<AppState>) -> Route {
    let input = Endpoint::new(EndpointType::Http(http));
    let output = Endpoint::new_response();
    // The HTTP inline-response fast path (see `make_http`) handles each request
    // directly, so the route's batch size is left at the library default.
    Route::new(input, output).with_handler(move |msg| handle(state.clone(), msg))
}
