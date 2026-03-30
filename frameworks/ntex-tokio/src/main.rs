use ntex::http::header::{CONTENT_TYPE, SERVER};
use ntex::util::BytesMut;
use ntex::web::{self, App, HttpResponse};
use ntex_files as fs;
use flate2::write::GzEncoder;
use flate2::Compression;
use std::io::Write;
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::sync::Arc;

static SERVER_NAME: &str = "ntex";

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

struct AppState {
    dataset: Vec<DatasetItem>,
    json_large_cache: Vec<u8>,
}

struct WorkerDb(RefCell<Option<Connection>>);

#[derive(Deserialize)]
struct BaselineParams {
    #[serde(default)]
    a: i64,
    #[serde(default)]
    b: i64,
}

#[derive(Deserialize)]
struct DbParams {
    #[serde(default = "default_min")]
    min: f64,
    #[serde(default = "default_max")]
    max: f64,
}

fn default_min() -> f64 {
    10.0
}
fn default_max() -> f64 {
    50.0
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn process_items(dataset: &[DatasetItem]) -> Vec<u8> {
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
    serde_json::to_vec(&resp).unwrap_or_default()
}

async fn pipeline() -> HttpResponse {
    HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "text/plain")
        .body("ok")
}

async fn baseline11_get(params: web::types::Query<BaselineParams>) -> HttpResponse {
    let sum = params.a + params.b;
    HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "text/plain")
        .body(sum.to_string())
}

async fn baseline11_post(
    params: web::types::Query<BaselineParams>,
    mut body: web::types::Payload,
) -> Result<HttpResponse, web::error::PayloadError> {
    let mut sum = params.a + params.b;
    let mut buf = BytesMut::new();
    while let Some(chunk) = ntex::util::stream_recv(&mut body).await {
        buf.extend_from_slice(&chunk?);
    }
    if let Ok(s) = std::str::from_utf8(&buf) {
        if let Ok(n) = s.trim().parse::<i64>() {
            sum += n;
        }
    }
    Ok(HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "text/plain")
        .body(sum.to_string()))
}

async fn baseline2(params: web::types::Query<BaselineParams>) -> HttpResponse {
    let sum = params.a + params.b;
    HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "text/plain")
        .body(sum.to_string())
}

async fn upload(mut body: web::types::Payload) -> Result<HttpResponse, web::error::PayloadError> {
    let mut len: usize = 0;
    while let Some(chunk) = ntex::util::stream_recv(&mut body).await {
        len += chunk?.len();
    }
    Ok(HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "text/plain")
        .body(len.to_string()))
}

async fn json_endpoint(state: web::types::State<Arc<AppState>>) -> HttpResponse {
    if state.dataset.is_empty() {
        return HttpResponse::InternalServerError().body("No dataset");
    }
    let body = process_items(&state.dataset);
    HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "application/json")
        .body(body)
}

async fn compression(state: web::types::State<Arc<AppState>>) -> HttpResponse {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(&state.json_large_cache).unwrap();
    let compressed = encoder.finish().unwrap();
    HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "application/json")
        .header("Content-Encoding", "gzip")
        .body(compressed)
}

async fn db_endpoint(
    params: web::types::Query<DbParams>,
    db: web::types::State<WorkerDb>,
) -> HttpResponse {
    let borrow = db.0.borrow();
    let conn = match borrow.as_ref() {
        Some(c) => c,
        None => {
            return HttpResponse::InternalServerError().body("Database not available");
        }
    };
    let mut stmt = conn
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50",
        )
        .unwrap();
    let rows = stmt.query_map(rusqlite::params![params.min, params.max], |row| {
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
    HttpResponse::Ok()
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "application/json")
        .body(result.to_string())
}

async fn async_db_endpoint(
    params: web::types::Query<DbParams>,
    pool: web::types::State<Option<Pool>>,
) -> HttpResponse {
    let pool = match pool.as_ref() {
        Some(p) => p,
        None => {
            return HttpResponse::Ok()
                .header(SERVER, SERVER_NAME)
                .header(CONTENT_TYPE, "application/json")
                .body(r#"{"items":[],"count":0}"#);
        }
    };
    let client = match pool.get().await {
        Ok(c) => c,
        Err(_) => {
            return HttpResponse::Ok()
                .header(SERVER, SERVER_NAME)
                .header(CONTENT_TYPE, "application/json")
                .body(r#"{"items":[],"count":0}"#);
        }
    };
    let stmt = match client
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50",
        )
        .await
    {
        Ok(s) => s,
        Err(_) => {
            return HttpResponse::Ok()
                .header(SERVER, SERVER_NAME)
                .header(CONTENT_TYPE, "application/json")
                .body(r#"{"items":[],"count":0}"#);
        }
    };
    let rows = match client.query(&stmt, &[&params.min, &params.max]).await {
        Ok(r) => r,
        Err(_) => {
            return HttpResponse::Ok()
                .header(SERVER, SERVER_NAME)
                .header(CONTENT_TYPE, "application/json")
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
        .header(SERVER, SERVER_NAME)
        .header(CONTENT_TYPE, "application/json")
        .body(result.to_string())
}

#[ntex::main]
async fn main() -> std::io::Result<()> {
    let dataset = load_dataset();

    let large_dataset: Vec<DatasetItem> =
        match std::fs::read_to_string("/data/dataset-large.json") {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Vec::new(),
        };
    let json_large_cache = process_items(&large_dataset);

    let state = Arc::new(AppState {
        dataset,
        json_large_cache,
    });

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

    let workers = num_cpus::get();

    web::server(async move || {
        let worker_db = Connection::open_with_flags(
            "/data/benchmark.db",
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .ok()
        .map(|conn| {
            conn.execute_batch("PRAGMA mmap_size=268435456").ok();
            conn
        });
        let db_state = WorkerDb(RefCell::new(worker_db));

        App::new()
            .state(state.clone())
            .state(db_state)
            .state(pg_pool.clone())
            .state(web::types::PayloadConfig::new(25 * 1024 * 1024))
            .route("/pipeline", web::get().to(pipeline))
            .route("/baseline11", web::get().to(baseline11_get))
            .route("/baseline11", web::post().to(baseline11_post))
            .route("/baseline2", web::get().to(baseline2))
            .route("/upload", web::post().to(upload))
            .route("/json", web::get().to(json_endpoint))
            .route("/compression", web::get().to(compression))
            .route("/db", web::get().to(db_endpoint))
            .route("/async-db", web::get().to(async_db_endpoint))
            .service(fs::Files::new("/static", "/data/static"))
    })
    .workers(workers)
    .backlog(4096)
    .bind("0.0.0.0:8080")?
    .run()
    .await
}
