use actix_files::Files;
use actix_web::http::header::{ContentType, HeaderValue, SERVER};
use actix_web::{web, App, HttpResponse, HttpServer};
use bytes::Bytes;
use deadpool_postgres::{Manager, ManagerConfig, Pool as PgPool, RecyclingMethod};
use futures_util::StreamExt;
use r2d2::Pool as SqlitePool;
use r2d2_sqlite::SqliteConnectionManager;
use rustls::ServerConfig;
use serde::{Deserialize, Serialize};
use std::io;

static SERVER_HDR: HeaderValue = HeaderValue::from_static("actix");

#[derive(Deserialize)]
struct BaselineQuery {
    a: Option<i64>,
    b: Option<i64>,
}

// Shared query struct for both DB endpoints — replaces manual query string parsing
#[derive(Deserialize)]
struct PriceQuery {
    min: Option<f64>,
    max: Option<f64>,
}

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

// AppState is wrapped by web::Data which is already an Arc — no need to double-wrap
struct AppState {
    dataset: Vec<DatasetItem>,
    // Bytes is cheaply cloneable (ref-counted), safe to clone per-request
    json_large_cache: Bytes,
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn build_json_cache(dataset: &[DatasetItem]) -> Bytes {
    let items: Vec<ProcessedItem> = dataset
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
        .collect();
    let resp = JsonResponse {
        count: items.len(),
        items,
    };
    Bytes::from(serde_json::to_vec(&resp).unwrap_or_default())
}

async fn pipeline() -> HttpResponse {
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body("ok")
}

async fn baseline11_get(query: web::Query<BaselineQuery>) -> HttpResponse {
    let sum = query.a.unwrap_or(0) + query.b.unwrap_or(0);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .body(sum.to_string())
}

async fn baseline11_post(query: web::Query<BaselineQuery>, body: web::Bytes) -> HttpResponse {
    let mut sum = query.a.unwrap_or(0) + query.b.unwrap_or(0);
    if let Ok(s) = std::str::from_utf8(&body) {
        if let Ok(n) = s.trim().parse::<i64>() {
            sum += n;
        }
    }
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body(sum.to_string())
}

async fn baseline2(query: web::Query<BaselineQuery>) -> HttpResponse {
    let sum = query.a.unwrap_or(0) + query.b.unwrap_or(0);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .body(sum.to_string())
}

async fn upload(mut payload: web::Payload) -> HttpResponse {
    let mut size: usize = 0;
    while let Some(chunk) = payload.next().await {
        if let Ok(data) = chunk {
            size += data.len();
        }
    }
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::plaintext())
        .body(size.to_string())
}

// web::Data<AppState> — no Arc wrapping, web::Data handles it internally
async fn json_endpoint(state: web::Data<AppState>) -> HttpResponse {
    if state.dataset.is_empty() {
        return HttpResponse::InternalServerError().body("No dataset");
    }
    let items: Vec<ProcessedItem> = state
        .dataset
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
        .collect();
    let resp = JsonResponse {
        count: items.len(),
        items,
    };
    let body = serde_json::to_vec(&resp).unwrap_or_default();
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::json())
        .body(body)
}

async fn compression(state: web::Data<AppState>) -> HttpResponse {
    // Bytes::clone() is O(1) — just increments a ref count
    HttpResponse::Ok()
        .insert_header(("Content-Type", "application/json"))
        .insert_header(("Server", "actix"))
        .body(state.json_large_cache.clone())
}

async fn db_endpoint(
    query: web::Query<PriceQuery>,
    pool: web::Data<Option<SqlitePool<SqliteConnectionManager>>>,
) -> HttpResponse {
    let pool = match pool.as_ref() {
        Some(p) => p.clone(),
        None => {
            return HttpResponse::Ok()
                .insert_header((SERVER, SERVER_HDR.clone()))
                .content_type(ContentType::json())
                .body(r#"{"items":[],"count":0}"#);
        }
    };
    let min = query.min.unwrap_or(10.0);
    let max = query.max.unwrap_or(50.0);

    // SQLite is synchronous — offload to the blocking thread pool so we don't stall the runtime
    let items = web::block(move || {
        let conn = pool.get().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
             FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50",
        ).unwrap();
        let rows = stmt.query_map(rusqlite::params![min, max], |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, i64>(0)?,
                "name": row.get::<_, String>(1)?,
                "category": row.get::<_, String>(2)?,
                "price": row.get::<_, f64>(3)?,
                "quantity": row.get::<_, i64>(4)?,
                "active": row.get::<_, i64>(5)? == 1,
                "tags": serde_json::from_str::<serde_json::Value>(
                    &row.get::<_, String>(6)?
                ).unwrap_or_default(),
                "rating": {
                    "score": row.get::<_, f64>(7)?,
                    "count": row.get::<_, i64>(8)?
                }
            }))
        }).unwrap();
        rows.filter_map(|r| r.ok()).collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default();

    let result = serde_json::json!({"items": items, "count": items.len()});
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::json())
        .body(result.to_string())
}

async fn pgdb_endpoint(
    query: web::Query<PriceQuery>,
    pool: web::Data<Option<PgPool>>,
) -> HttpResponse {
    let pool = match pool.as_ref() {
        Some(p) => p,
        None => {
            return HttpResponse::Ok()
                .insert_header((SERVER, SERVER_HDR.clone()))
                .content_type(ContentType::json())
                .body(r#"{"items":[],"count":0}"#);
        }
    };
    let min = query.min.unwrap_or(10.0);
    let max = query.max.unwrap_or(50.0);

    let client = match pool.get().await {
        Ok(c) => c,
        Err(_) => {
            return HttpResponse::Ok()
                .insert_header((SERVER, SERVER_HDR.clone()))
                .content_type(ContentType::json())
                .body(r#"{"items":[],"count":0}"#);
        }
    };
    let stmt = client
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
             FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50",
        )
        .await
        .unwrap();
    let rows = match client.query(&stmt, &[&min, &max]).await {
        Ok(r) => r,
        Err(_) => {
            return HttpResponse::Ok()
                .insert_header((SERVER, SERVER_HDR.clone()))
                .content_type(ContentType::json())
                .body(r#"{"items":[],"count":0}"#);
        }
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
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::json())
        .body(result.to_string())
}

fn load_tls_config() -> Option<ServerConfig> {
    let cert_path = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key_path = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    let cert_file = std::fs::File::open(&cert_path).ok()?;
    let key_file = std::fs::File::open(&key_path).ok()?;
    let certs: Vec<_> = rustls_pemfile::certs(&mut io::BufReader::new(cert_file))
        .filter_map(|r| r.ok())
        .collect();
    let key = rustls_pemfile::private_key(&mut io::BufReader::new(key_file)).ok()??;
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .ok()?;
    config.alpn_protocols = vec![b"h2".to_vec()];
    Some(config)
}

#[actix_web::main]
async fn main() -> io::Result<()> {
    let dataset = load_dataset();

    let large_dataset: Vec<DatasetItem> =
        match std::fs::read_to_string("/data/dataset-large.json") {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Vec::new(),
        };
    let json_large_cache = build_json_cache(&large_dataset);

    // web::Data::new() wraps in Arc internally — no manual Arc needed
    let state = web::Data::new(AppState {
        dataset,
        json_large_cache,
    });

    let pg_pool: Option<PgPool> = std::env::var("DATABASE_URL").ok().and_then(|url| {
        let pg_config: tokio_postgres::Config = url.parse().ok()?;
        let mgr = Manager::from_config(
            pg_config,
            deadpool_postgres::tokio_postgres::NoTls,
            ManagerConfig {
                recycling_method: RecyclingMethod::Fast,
            },
        );
        let pool_size = (num_cpus::get() * 4).max(64);
        PgPool::builder(mgr).max_size(pool_size).build().ok()
    });

    // r2d2 pool shared across all workers — each get() hands out a connection from the pool
    let sqlite_pool: Option<SqlitePool<SqliteConnectionManager>> = {
        let mgr = SqliteConnectionManager::file("/data/benchmark.db")
            .with_flags(rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .with_init(|conn| conn.execute_batch("PRAGMA mmap_size=268435456"));
        r2d2::Pool::builder().max_size(16).build(mgr).ok()
    };

    let tls_config = load_tls_config();
    let workers = num_cpus::get();

    let mut server = HttpServer::new({
        let state = state.clone();
        let pg_pool = pg_pool.clone();
        let sqlite_pool = sqlite_pool.clone();
        move || {
            App::new()
                .wrap(actix_web::middleware::Compress::default())
                .app_data(state.clone())
                .app_data(web::Data::new(sqlite_pool.clone()))
                .app_data(web::PayloadConfig::new(25 * 1024 * 1024))
                .app_data(web::Data::new(pg_pool.clone()))
                .route("/pipeline", web::get().to(pipeline))
                .route("/baseline11", web::get().to(baseline11_get))
                .route("/baseline11", web::post().to(baseline11_post))
                .route("/baseline2", web::get().to(baseline2))
                .route("/json", web::get().to(json_endpoint))
                .route("/compression", web::get().to(compression))
                .route("/db", web::get().to(db_endpoint))
                .route("/upload", web::post().to(upload))
                .route("/async-db", web::get().to(pgdb_endpoint))
                .service(Files::new("/static", "/data/static"))
        }
    })
    .workers(workers)
    .backlog(4096)
    .bind("0.0.0.0:8080")?;

    if let Some(tls_cfg) = tls_config {
        server = server.bind_rustls_0_23("0.0.0.0:8443", tls_cfg)?;
    }

    server.run().await
}