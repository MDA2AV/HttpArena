use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, StatusCode},
    response::Response,
    routing::{get, post},
    Router,
};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use flate2::write::GzEncoder;
use flate2::Compression;
use futures::StreamExt;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

// ─── Data types ───

#[derive(Deserialize, Clone)]
struct Rating {
    score: f64,
    count: i64,
}

#[derive(Deserialize, Clone)]
struct DatasetItem {
    id: i64,
    name: String,
    category: String,
    price: f64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: Rating,
}

#[derive(Serialize)]
struct RatingOut {
    score: f64,
    count: i64,
}

#[derive(Serialize)]
struct ProcessedItem {
    id: i64,
    name: String,
    category: String,
    price: f64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: RatingOut,
    total: f64,
}

#[derive(Serialize)]
struct JsonResponse {
    items: Vec<ProcessedItem>,
    count: usize,
}

// ─── App state ───

struct StaticFile {
    data: Vec<u8>,
    content_type: String,
}

struct AppState {
    dataset: Vec<DatasetItem>,
    json_large_cache: Vec<u8>,
    static_files: HashMap<String, StaticFile>,
    db_pool: Vec<Mutex<Connection>>,
    db_counter: AtomicUsize,
    pg_pool: Option<Pool>,
}

fn process_items(dataset: &[DatasetItem]) -> Vec<ProcessedItem> {
    dataset
        .iter()
        .map(|d| ProcessedItem {
            id: d.id,
            name: d.name.clone(),
            category: d.category.clone(),
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: d.tags.clone(),
            rating: RatingOut {
                score: d.rating.score,
                count: d.rating.count,
            },
            total: (d.price * d.quantity as f64 * 100.0).round() / 100.0,
        })
        .collect()
}

fn build_json_cache(dataset: &[DatasetItem]) -> Vec<u8> {
    let items = process_items(dataset);
    let resp = JsonResponse {
        count: items.len(),
        items,
    };
    serde_json::to_vec(&resp).unwrap_or_default()
}

fn gzip_compress(data: &[u8]) -> Vec<u8> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(data).unwrap();
    encoder.finish().unwrap()
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn load_static_files() -> HashMap<String, StaticFile> {
    let mime_types: HashMap<&str, &str> = [
        (".css", "text/css"),
        (".js", "application/javascript"),
        (".html", "text/html"),
        (".woff2", "font/woff2"),
        (".svg", "image/svg+xml"),
        (".webp", "image/webp"),
        (".json", "application/json"),
    ]
    .into();
    let mut files = HashMap::new();
    if let Ok(entries) = std::fs::read_dir("/data/static") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Ok(data) = std::fs::read(entry.path()) {
                let ext = name.rfind('.').map(|i| &name[i..]).unwrap_or("");
                let ct = mime_types.get(ext).unwrap_or(&"application/octet-stream");
                files.insert(
                    name,
                    StaticFile {
                        data,
                        content_type: ct.to_string(),
                    },
                );
            }
        }
    }
    files
}

fn open_db_pool(count: usize) -> Vec<Mutex<Connection>> {
    let db_path = "/data/benchmark.db";
    if !std::path::Path::new(db_path).exists() {
        return Vec::new();
    }
    (0..count)
        .filter_map(|_| {
            let conn = Connection::open_with_flags(
                db_path,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            )
            .ok()?;
            conn.execute_batch("PRAGMA mmap_size=268435456").ok();
            Some(Mutex::new(conn))
        })
        .collect()
}

fn parse_query_sum(query: &str) -> i64 {
    let mut sum: i64 = 0;
    for pair in query.split('&') {
        if let Some(val) = pair.split('=').nth(1) {
            if let Ok(n) = val.parse::<i64>() {
                sum += n;
            }
        }
    }
    sum
}

fn parse_query_param(query: &str, name: &str) -> Option<f64> {
    for pair in query.split('&') {
        if let Some(v) = pair.strip_prefix(name).and_then(|s| s.strip_prefix('=')) {
            if let Ok(n) = v.parse() {
                return Some(n);
            }
        }
    }
    None
}

// ─── Helper to build response with Server header ───

fn server_response(body: Vec<u8>, content_type: &str) -> Response {
    Response::builder()
        .header(header::SERVER, "axum")
        .header(header::CONTENT_TYPE, content_type)
        .body(Body::from(body))
        .unwrap()
}

fn text_response(body: String) -> Response {
    server_response(body.into_bytes(), "text/plain")
}

fn json_response(body: Vec<u8>) -> Response {
    server_response(body, "application/json")
}

fn error_response(status: StatusCode, msg: &str) -> Response {
    Response::builder()
        .status(status)
        .header(header::SERVER, "axum")
        .header(header::CONTENT_TYPE, "text/plain")
        .body(Body::from(msg.to_string()))
        .unwrap()
}

// ─── Routes ───

async fn pipeline() -> Response {
    text_response("ok".to_string())
}

async fn baseline11_get(
    axum::extract::RawQuery(raw_query): axum::extract::RawQuery,
) -> Response {
    let sum = raw_query.as_deref().map(parse_query_sum).unwrap_or(0);
    text_response(sum.to_string())
}

async fn baseline11_post(
    axum::extract::RawQuery(raw_query): axum::extract::RawQuery,
    body: axum::body::Bytes,
) -> Response {
    let mut sum = raw_query.as_deref().map(parse_query_sum).unwrap_or(0);
    if let Ok(s) = std::str::from_utf8(&body) {
        if let Ok(n) = s.trim().parse::<i64>() {
            sum += n;
        }
    }
    text_response(sum.to_string())
}

async fn baseline2(
    axum::extract::RawQuery(raw_query): axum::extract::RawQuery,
) -> Response {
    let sum = raw_query.as_deref().map(parse_query_sum).unwrap_or(0);
    text_response(sum.to_string())
}

async fn json_endpoint(State(state): State<Arc<AppState>>) -> Response {
    if state.dataset.is_empty() {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, "No dataset");
    }
    let items = process_items(&state.dataset);
    let resp = JsonResponse {
        count: items.len(),
        items,
    };
    json_response(serde_json::to_vec(&resp).unwrap_or_default())
}

async fn compression_endpoint(State(state): State<Arc<AppState>>) -> Response {
    if state.json_large_cache.is_empty() {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, "No dataset");
    }
    let compressed = gzip_compress(&state.json_large_cache);
    Response::builder()
        .header(header::SERVER, "axum")
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::CONTENT_ENCODING, "gzip")
        .body(Body::from(compressed))
        .unwrap()
}

async fn db_endpoint(
    State(state): State<Arc<AppState>>,
    axum::extract::RawQuery(raw_query): axum::extract::RawQuery,
) -> Response {
    let query = raw_query.as_deref().unwrap_or("");
    let min = parse_query_param(query, "min").unwrap_or(10.0);
    let max = parse_query_param(query, "max").unwrap_or(50.0);

    if state.db_pool.is_empty() {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, "Database not available");
    }

    let idx = state.db_counter.fetch_add(1, Ordering::Relaxed) % state.db_pool.len();
    let conn = state.db_pool[idx].lock().unwrap();
    let mut stmt = conn
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50",
        )
        .unwrap();
    let rows = stmt.query_map(rusqlite::params![min, max], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, i64>(0)?,
            "name": row.get::<_, String>(1)?,
            "category": row.get::<_, String>(2)?,
            "price": row.get::<_, f64>(3)?,
            "quantity": row.get::<_, i64>(4)?,
            "active": row.get::<_, i64>(5)? == 1,
            "tags": serde_json::from_str::<serde_json::Value>(&row.get::<_, String>(6)?).unwrap_or_default(),
            "rating": serde_json::json!({
                "score": row.get::<_, f64>(7)?,
                "count": row.get::<_, i64>(8)?
            })
        }))
    });
    let items: Vec<serde_json::Value> = match rows {
        Ok(mapped) => mapped.filter_map(|r| r.ok()).collect(),
        Err(_) => Vec::new(),
    };
    let result = serde_json::json!({"items": items, "count": items.len()});
    json_response(serde_json::to_vec(&result).unwrap_or_default())
}

async fn async_db_endpoint(
    State(state): State<Arc<AppState>>,
    axum::extract::RawQuery(raw_query): axum::extract::RawQuery,
) -> Response {
    let pool = match state.pg_pool.as_ref() {
        Some(p) => p,
        None => return json_response(br#"{"items":[],"count":0}"#.to_vec()),
    };
    let query = raw_query.as_deref().unwrap_or("");
    let min: f64 = parse_query_param(query, "min").unwrap_or(10.0);
    let max: f64 = parse_query_param(query, "max").unwrap_or(50.0);
    let client = match pool.get().await {
        Ok(c) => c,
        Err(_) => return json_response(br#"{"items":[],"count":0}"#.to_vec()),
    };
    let stmt = match client
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50",
        )
        .await
    {
        Ok(s) => s,
        Err(_) => return json_response(br#"{"items":[],"count":0}"#.to_vec()),
    };
    let rows = match client.query(&stmt, &[&min, &max]).await {
        Ok(r) => r,
        Err(_) => return json_response(br#"{"items":[],"count":0}"#.to_vec()),
    };
    let items: Vec<serde_json::Value> = rows
        .iter()
        .map(|row| {
            serde_json::json!({
                "id": row.get::<_, i32>(0) as i64,
                "name": row.get::<_, &str>(1),
                "category": row.get::<_, &str>(2),
                "price": row.get::<_, f64>(3),
                "quantity": row.get::<_, i32>(4) as i64,
                "active": row.get::<_, bool>(5),
                "tags": row.get::<_, serde_json::Value>(6),
                "rating": {
                    "score": row.get::<_, f64>(7),
                    "count": row.get::<_, i32>(8) as i64,
                }
            })
        })
        .collect();
    let result = serde_json::json!({"items": items, "count": items.len()});
    json_response(serde_json::to_vec(&result).unwrap_or_default())
}

async fn upload_endpoint(body: Body) -> Response {
    let mut stream = body.into_data_stream();
    let mut size: usize = 0;
    while let Some(Ok(chunk)) = stream.next().await {
        size += chunk.len();
    }
    text_response(size.to_string())
}

async fn static_file(
    State(state): State<Arc<AppState>>,
    Path(filename): Path<String>,
) -> Response {
    if let Some(sf) = state.static_files.get(&filename) {
        Response::builder()
            .header(header::SERVER, "axum")
            .header(header::CONTENT_TYPE, &sf.content_type)
            .body(Body::from(sf.data.clone()))
            .unwrap()
    } else {
        error_response(StatusCode::NOT_FOUND, "Not Found")
    }
}

// ─── Build router ───

fn build_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/pipeline", get(pipeline))
        .route("/baseline11", get(baseline11_get).post(baseline11_post))
        .route("/baseline2", get(baseline2))
        .route("/json", get(json_endpoint))
        .route("/compression", get(compression_endpoint))
        .route("/db", get(db_endpoint))
        .route("/async-db", get(async_db_endpoint))
        .route("/upload", post(upload_endpoint))
        .route("/static/{filename}", get(static_file))
        .with_state(state)
}

// ─── Main ───

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let workers = std::env::var("AXUM_WORKERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(num_cpus::get);

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .enable_all()
        .build()?;

    rt.block_on(async_main(workers))
}

async fn async_main(workers: usize) -> Result<(), Box<dyn std::error::Error>> {
    let dataset = load_dataset();
    let large_dataset: Vec<DatasetItem> =
        match std::fs::read_to_string("/data/dataset-large.json") {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Vec::new(),
        };
    let json_large_cache = build_json_cache(&large_dataset);

    let pg_pool: Option<Pool> = std::env::var("DATABASE_URL").ok().and_then(|url| {
        let pg_config: tokio_postgres::Config = url.parse().ok()?;
        let mgr = Manager::from_config(
            pg_config,
            deadpool_postgres::tokio_postgres::NoTls,
            ManagerConfig {
                recycling_method: RecyclingMethod::Fast,
            },
        );
        let pool_size = (num_cpus::get() * 4).max(64);
        Pool::builder(mgr).max_size(pool_size).build().ok()
    });

    let state = Arc::new(AppState {
        dataset,
        json_large_cache,
        static_files: load_static_files(),
        db_pool: open_db_pool(workers),
        db_counter: AtomicUsize::new(0),
        pg_pool,
    });

    let cert_path = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key_path = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    let has_tls =
        std::path::Path::new(&cert_path).exists() && std::path::Path::new(&key_path).exists();

    let app = build_router(state.clone());

    if has_tls {
        let tls_app = build_router(state.clone());

        let tls_config = axum_server::tls_rustls::RustlsConfig::from_pem_file(&cert_path, &key_path)
            .await?;

        let http_handle = tokio::spawn(async move {
            let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
            let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
            axum::serve(listener, app).await.unwrap();
        });

        let tls_handle = tokio::spawn(async move {
            let addr = SocketAddr::from(([0, 0, 0, 0], 8443));
            axum_server::bind_rustls(addr, tls_config)
                .serve(tls_app.into_make_service())
                .await
                .unwrap();
        });

        let _ = tokio::try_join!(http_handle, tls_handle);
    } else {
        let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
        let listener = tokio::net::TcpListener::bind(addr).await?;
        axum::serve(listener, app).await?;
    }

    Ok(())
}
