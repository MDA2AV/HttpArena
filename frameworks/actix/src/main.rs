fn cgroup_cpus() -> usize {
    std::fs::read_to_string("/sys/fs/cgroup/cpu.max")
        .ok()
        .and_then(|s| {
            let mut parts = s.trim().split(' ');
            let quota = parts.next()?;
            if quota == "max" { return None; }
            let period: usize = parts.next()?.parse().ok()?;
            let q: usize = quota.parse().ok()?;
            let cpus = q / period;
            if cpus >= 1 { Some(cpus) } else { None }
        })
        .unwrap_or_else(num_cpus::get)
}

use actix_files::Files;
use actix_web::http::header::{ContentType, HeaderValue, SERVER};
use actix_web::middleware::Compress;
use actix_web::{web, App, HttpResponse, HttpServer};
use dashmap::DashMap;
use deadpool_postgres::{Manager, ManagerConfig, Pool as PgPool, RecyclingMethod};
use futures_util::StreamExt;
use rustls::ServerConfig;
use serde::{Deserialize, Serialize};
use std::io;

static SERVER_HDR: HeaderValue = HeaderValue::from_static("actix");

// In-memory cache-aside store for the crud read path: item id -> rendered JSON
// body. Populated on GET miss, invalidated on update. No Redis required.
type CrudCache = DashMap<i64, Vec<u8>>;

#[derive(Deserialize)]
struct BaselineQuery {
    a: Option<i64>,
    b: Option<i64>,
}

// Shared query struct for both DB endpoints — replaces manual query string parsing
#[derive(Deserialize)]
struct PriceQuery {
    min: Option<i32>,
    max: Option<i32>,
    limit: Option<i32>,
}

#[derive(Deserialize)]
struct JsonQuery {
    m: Option<i64>,
}

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

#[derive(Serialize, Clone)]
struct RatingOut {
    score: i64,
    count: i64,
}

#[derive(Serialize, Clone)]
struct ProcessedItem {
    id: i64,
    name: String,
    category: String,
    price: i64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: RatingOut,
    total: i64,
}

#[derive(Serialize)]
struct JsonResponse {
    items: Vec<ProcessedItem>,
    count: usize,
}

// CRUD request bodies / query.
#[derive(Deserialize)]
struct CrudListQuery {
    category: Option<String>,
    page: Option<i64>,
    limit: Option<i64>,
}

#[derive(Deserialize)]
struct CrudCreate {
    id: i64,
    name: String,
    category: String,
    price: i32,
    quantity: i32,
}

#[derive(Deserialize)]
struct CrudUpdate {
    name: String,
    category: String,
    price: i32,
    quantity: i32,
}

struct AppState {
    dataset: Vec<DatasetItem>,
}

fn build_json_body(dataset: &[DatasetItem], count: usize, m: i64) -> Vec<u8> {
    let count = count.min(dataset.len());
    let items: Vec<ProcessedItem> = dataset[..count]
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
            total: d.price * d.quantity * m,
        })
        .collect();
    let resp = JsonResponse { count, items };
    serde_json::to_vec(&resp).unwrap_or_default()
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
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
        .content_type(ContentType::plaintext())
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
        .content_type(ContentType::plaintext())
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

// JSON endpoint. Serialize fresh per request with serde_json; the Compress
// middleware on the App handles Accept-Encoding negotiation and response
// encoding so the handler body stays encoding-agnostic.
async fn json_endpoint(
    state: web::Data<AppState>,
    path: web::Path<usize>,
    query: web::Query<JsonQuery>,
) -> HttpResponse {
    let count = path.into_inner().min(state.dataset.len());
    let m = query.m.unwrap_or(1);
    let body = build_json_body(&state.dataset, count, m);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::json())
        .body(body)
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
    let min: i32 = query.min.unwrap_or(10);
    let max: i32 = query.max.unwrap_or(50);
    let limit: i64 = query.limit.unwrap_or(50).clamp(1, 50) as i64;

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
             FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
        )
        .await
        .unwrap();
    let rows = match client.query(&stmt, &[&min, &max, &limit]).await {
        Ok(r) => r,
        Err(_) => {
            return HttpResponse::Ok()
                .insert_header((SERVER, SERVER_HDR.clone()))
                .content_type(ContentType::json())
                .body(r#"{"items":[],"count":0}"#);
        }
    };
    let items: Vec<serde_json::Value> = rows.iter().map(row_to_item).collect();
    let result = serde_json::json!({"items": items, "count": items.len()});
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::json())
        .body(result.to_string())
}

// ───── CRUD (/crud/items) ─────
//
// List + read + create + update over the same `items` table the async-db
// endpoint uses. Reads go through an in-memory cache-aside (X-Cache MISS/HIT),
// invalidated on update — no Redis required.

const CRUD_COLS: &str =
    "id, name, category, price, quantity, active, tags, rating_score, rating_count";

fn row_to_item(row: &tokio_postgres::Row) -> serde_json::Value {
    serde_json::json!({
        "id": row.get::<_, i32>(0) as i64,
        "name": row.get::<_, &str>(1),
        "category": row.get::<_, &str>(2),
        "price": row.get::<_, i32>(3),
        "quantity": row.get::<_, i32>(4),
        "active": row.get::<_, bool>(5),
        "tags": row.get::<_, serde_json::Value>(6),
        "rating": {
            "score": row.get::<_, i32>(7),
            "count": row.get::<_, i32>(8) as i64,
        }
    })
}

fn json_body(body: Vec<u8>) -> HttpResponse {
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type(ContentType::json())
        .body(body)
}

async fn crud_list(
    query: web::Query<CrudListQuery>,
    pool: web::Data<Option<PgPool>>,
) -> HttpResponse {
    let pool = match pool.as_ref() {
        Some(p) => p,
        None => return json_body(br#"{"items":[],"total":0,"page":1}"#.to_vec()),
    };
    let category = query.category.clone().unwrap_or_default();
    let page = query.page.unwrap_or(1).max(1);
    let limit = query.limit.unwrap_or(20).clamp(1, 100);
    let offset = (page - 1) * limit;

    let client = match pool.get().await {
        Ok(c) => c,
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };
    let list_sql =
        format!("SELECT {CRUD_COLS} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3");
    let stmt = match client.prepare_cached(&list_sql).await {
        Ok(s) => s,
        Err(_) => return HttpResponse::InternalServerError().finish(),
    };
    let rows = match client.query(&stmt, &[&category, &limit, &offset]).await {
        Ok(r) => r,
        Err(_) => return HttpResponse::InternalServerError().finish(),
    };
    let items: Vec<serde_json::Value> = rows.iter().map(row_to_item).collect();

    let count_stmt = match client
        .prepare_cached("SELECT COUNT(*) FROM items WHERE category = $1")
        .await
    {
        Ok(s) => s,
        Err(_) => return HttpResponse::InternalServerError().finish(),
    };
    let total: i64 = client
        .query_one(&count_stmt, &[&category])
        .await
        .map(|r| r.get::<_, i64>(0))
        .unwrap_or(0);

    let body = serde_json::json!({ "items": items, "total": total, "page": page });
    json_body(body.to_string().into_bytes())
}

async fn crud_get(
    id: web::Path<i64>,
    pool: web::Data<Option<PgPool>>,
    cache: web::Data<CrudCache>,
) -> HttpResponse {
    let id = id.into_inner();
    if let Some(cached) = cache.get(&id) {
        return HttpResponse::Ok()
            .insert_header((SERVER, SERVER_HDR.clone()))
            .insert_header(("X-Cache", "HIT"))
            .content_type(ContentType::json())
            .body(cached.value().clone());
    }
    let pool = match pool.as_ref() {
        Some(p) => p,
        None => return HttpResponse::ServiceUnavailable().finish(),
    };
    let client = match pool.get().await {
        Ok(c) => c,
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };
    let sql = format!("SELECT {CRUD_COLS} FROM items WHERE id = $1");
    let stmt = match client.prepare_cached(&sql).await {
        Ok(s) => s,
        Err(_) => return HttpResponse::InternalServerError().finish(),
    };
    match client.query_opt(&stmt, &[&(id as i32)]).await {
        Ok(Some(row)) => {
            let body = row_to_item(&row).to_string().into_bytes();
            cache.insert(id, body.clone());
            HttpResponse::Ok()
                .insert_header((SERVER, SERVER_HDR.clone()))
                .insert_header(("X-Cache", "MISS"))
                .content_type(ContentType::json())
                .body(body)
        }
        Ok(None) => HttpResponse::NotFound()
            .insert_header((SERVER, SERVER_HDR.clone()))
            .finish(),
        Err(_) => HttpResponse::InternalServerError().finish(),
    }
}

async fn crud_create(
    item: web::Json<CrudCreate>,
    pool: web::Data<Option<PgPool>>,
    cache: web::Data<CrudCache>,
) -> HttpResponse {
    let pool = match pool.as_ref() {
        Some(p) => p,
        None => return HttpResponse::ServiceUnavailable().finish(),
    };
    let client = match pool.get().await {
        Ok(c) => c,
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };
    let stmt = match client
        .prepare_cached(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) \
             VALUES ($1, $2, $3, $4, $5, false, '[]'::jsonb, 0, 0) \
             ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, \
             price = EXCLUDED.price, quantity = EXCLUDED.quantity",
        )
        .await
    {
        Ok(s) => s,
        Err(_) => return HttpResponse::InternalServerError().finish(),
    };
    match client
        .execute(
            &stmt,
            &[&(item.id as i32), &item.name, &item.category, &item.price, &item.quantity],
        )
        .await
    {
        Ok(_) => {
            cache.remove(&item.id);
            HttpResponse::Created()
                .insert_header((SERVER, SERVER_HDR.clone()))
                .finish()
        }
        Err(_) => HttpResponse::InternalServerError().finish(),
    }
}

async fn crud_update(
    id: web::Path<i64>,
    item: web::Json<CrudUpdate>,
    pool: web::Data<Option<PgPool>>,
    cache: web::Data<CrudCache>,
) -> HttpResponse {
    let id = id.into_inner();
    let pool = match pool.as_ref() {
        Some(p) => p,
        None => return HttpResponse::ServiceUnavailable().finish(),
    };
    let client = match pool.get().await {
        Ok(c) => c,
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };
    let stmt = match client
        .prepare_cached(
            "UPDATE items SET name = $2, category = $3, price = $4, quantity = $5 WHERE id = $1",
        )
        .await
    {
        Ok(s) => s,
        Err(_) => return HttpResponse::InternalServerError().finish(),
    };
    let updated = client
        .execute(
            &stmt,
            &[&(id as i32), &item.name, &item.category, &item.price, &item.quantity],
        )
        .await
        .unwrap_or(0);
    // Invalidate the cached read so the next GET re-fetches from the DB (X-Cache: MISS).
    cache.remove(&id);
    if updated > 0 {
        HttpResponse::Ok()
            .insert_header((SERVER, SERVER_HDR.clone()))
            .finish()
    } else {
        HttpResponse::NotFound()
            .insert_header((SERVER, SERVER_HDR.clone()))
            .finish()
    }
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
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .ok()?;
    // actix-web always enables ALPN "h2" and "http/1.1" on a rustls listener, so
    // the same config serves baseline-h2/static-h2 (negotiating h2 on :8443) and
    // json-tls (negotiating http/1.1 on :8081). No manual alpn_protocols needed.
    Some(config)
}

#[actix_web::main]
async fn main() -> io::Result<()> {
    let dataset = load_dataset();
    let state = web::Data::new(AppState { dataset });
    let crud_cache: web::Data<CrudCache> = web::Data::new(DashMap::new());

    let pg_pool: Option<PgPool> = std::env::var("DATABASE_URL").ok().and_then(|url| {
        let pg_config: tokio_postgres::Config = url.parse().ok()?;
        let mgr = Manager::from_config(
            pg_config,
            deadpool_postgres::tokio_postgres::NoTls,
            ManagerConfig {
                recycling_method: RecyclingMethod::Fast,
            },
        );
        let pool_size: usize = std::env::var("DATABASE_MAX_CONN")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(256);
        PgPool::builder(mgr).max_size(pool_size).build().ok()
    });

    let workers = cgroup_cpus();

    let mut server = HttpServer::new({
        let state = state.clone();
        let pg_pool = pg_pool.clone();
        let crud_cache = crud_cache.clone();
        move || {
            App::new()
                // Compress middleware performs on-the-fly response compression
                // based on the request's Accept-Encoding. Framework-standard —
                // no handmade gzip/brotli. It skips responses that already carry
                // a Content-Encoding (i.e. the pre-compressed static files below).
                .wrap(Compress::default())
                .app_data(state.clone())
                .app_data(web::PayloadConfig::new(25 * 1024 * 1024))
                .app_data(web::Data::new(pg_pool.clone()))
                .app_data(crud_cache.clone())
                .route("/pipeline", web::get().to(pipeline))
                .route("/baseline11", web::get().to(baseline11_get))
                .route("/baseline11", web::post().to(baseline11_post))
                .route("/baseline2", web::get().to(baseline2))
                .route("/upload", web::post().to(upload))
                .route("/async-db", web::get().to(pgdb_endpoint))
                .route("/json/{count}", web::get().to(json_endpoint))
                .route("/crud/items", web::get().to(crud_list))
                .route("/crud/items", web::post().to(crud_create))
                .route("/crud/items/{id}", web::get().to(crud_get))
                .route("/crud/items/{id}", web::put().to(crud_update))
                // actix-files serves from disk per request. `try_compressed()`
                // selects a pre-compressed .br/.gz sibling by Accept-Encoding
                // (framework API — no hand-rolled suffix lookup), falling back to
                // the identity file when no variant exists. Reading per request
                // keeps it freshness-compliant (no permanent in-memory cache).
                .service(
                    Files::new("/static", "/data/static").try_compressed(),
                )
        }
    })
    .workers(workers)
    .bind("0.0.0.0:8080")?;

    // TLS listeners. :8443 carries h2 (baseline-h2/static-h2); :8081 carries
    // HTTP/1.1-over-TLS (json-tls). Both use the same cert + ALPN (h2,http/1.1);
    // the client picks the protocol.
    if let Some(tls_cfg) = load_tls_config() {
        server = server.bind_rustls_0_23("0.0.0.0:8443", tls_cfg)?;
    }
    if let Some(tls_cfg) = load_tls_config() {
        server = server.bind_rustls_0_23("0.0.0.0:8081", tls_cfg)?;
    }

    server.run().await
}
