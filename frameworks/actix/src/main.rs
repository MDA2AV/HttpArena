use actix_files::Files;
use actix_web::http::header::{self, ContentType};
use actix_web::middleware::Compress;
use actix_web::{web, App, HttpRequest, HttpResponse, HttpServer};
use futures_util::StreamExt;
use rustls::ServerConfig;
use serde::{Deserialize, Serialize};
use std::io;

mod db;
mod fortunes;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

/// The dataset, loaded once and leaked, so every worker borrows the same items.
type Dataset = web::ThinData<&'static [DatasetItem]>;

#[derive(Deserialize)]
struct BaselineQuery {
    a: Option<i64>,
    b: Option<i64>,
}

#[derive(Deserialize)]
struct JsonQuery {
    m: Option<i64>,
}

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

// Field order is the wire order: id..rating, then the computed total.
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

// The first `count` items with their totals. Strings and tags are borrowed from
// the dataset: the response is still built and serialized on every request, it
// just does not copy every name, category and tag into it first.
fn build_json(dataset: &[DatasetItem], count: usize, m: i64) -> JsonResponse<'_> {
    let count = count.min(dataset.len());
    let items = dataset[..count]
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
    JsonResponse { items, count }
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

// actix-web re-exports its runtime, so the sleep comes from there rather than from a direct
// tokio dependency the entry does not have. It parks the task rather than the thread, so the
// waits in flight are bounded by memory rather than by the worker count.
async fn delay(path: web::Path<u64>) -> HttpResponse {
    let ms = path.into_inner();
    if ms > 0 {
        actix_web::rt::time::sleep(std::time::Duration::from_millis(ms)).await;
    }
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(ms.to_string())
}

async fn pipeline() -> HttpResponse {
    HttpResponse::Ok().content_type("text/plain").body("ok")
}

async fn baseline11_get(query: web::Query<BaselineQuery>) -> HttpResponse {
    let sum = query.a.unwrap_or(0) + query.b.unwrap_or(0);
    HttpResponse::Ok()
        .content_type("text/plain")
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
        .content_type("text/plain")
        .body(sum.to_string())
}

async fn baseline2(query: web::Query<BaselineQuery>) -> HttpResponse {
    let sum = query.a.unwrap_or(0) + query.b.unwrap_or(0);
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(sum.to_string())
}

// Echo: the bytes that arrived go back unchanged. The payload is collected
// first because the response cannot be framed until the length is known --
// which is also what makes a chunked request work, since there is no
// Content-Length to read it from.
async fn echo_body(mut payload: web::Payload) -> HttpResponse {
    let mut body = web::BytesMut::new();
    while let Some(chunk) = payload.next().await {
        match chunk {
            Ok(data) => body.extend_from_slice(&data),
            Err(_) => return HttpResponse::BadRequest().finish(),
        }
    }
    HttpResponse::Ok()
        .content_type(ContentType::octet_stream())
        .body(body.freeze())
}

// JSON endpoint. Serialized fresh per request with serde_json.
//
// gzip is driven directly here rather than left to the Compress middleware.
// actix-web's encoder compresses in place only below
// MAX_CHUNK_SIZE_ENCODE_IN_PLACE (1 KiB) and hands everything larger to
// `spawn_blocking`; every response on this profile is 2-6 KB, so each one paid
// a blocking-pool round trip. That showed up as a server sitting at 66% CPU
// while serving 12k req/s - not compute-bound, waiting on thread handoff - and
// as throughput that climbed with connection count instead of flattening.
// Level 1 is what the profile asks for and what actix-web's own gzip path uses
// (`flate2::Compression::fast()`), so the bytes on the wire are unchanged; only
// the thread they are produced on is.
//
// The Compress middleware stays wrapped on this resource and skips the gzip
// response, because it already carries a Content-Encoding.
async fn json_endpoint(
    web::ThinData(dataset): Dataset,
    req: HttpRequest,
    path: web::Path<usize>,
    query: web::Query<JsonQuery>,
) -> HttpResponse {
    use std::io::Write as _;

    let list = build_json(dataset, path.into_inner(), query.m.unwrap_or(1));

    let accepts_gzip = req
        .headers()
        .get(header::ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.contains("gzip"));

    if accepts_gzip {
        if let Ok(body) = serde_json::to_vec(&list) {
            let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(1));
            if enc.write_all(&body).is_ok() {
                if let Ok(compressed) = enc.finish() {
                    return HttpResponse::Ok()
                        .insert_header((header::CONTENT_ENCODING, "gzip"))
                        .insert_header((header::VARY, "Accept-Encoding"))
                        .content_type(ContentType::json())
                        .body(compressed);
                }
            }
        }
    }

    HttpResponse::Ok().json(&list)
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
    // Leaked once at startup so handlers borrow the items instead of cloning
    // every string into each response.
    let dataset: &'static [DatasetItem] = Box::leak(load_dataset().into_boxed_slice());

    // One worker per CPU the container may use, which is also actix-web's
    // default. Taken here so the workers can split DATABASE_MAX_CONN evenly.
    let workers = std::thread::available_parallelism().map_or(1, |n| n.get());
    db::set_workers(workers);

    let mut server = HttpServer::new(move || {
        App::new()
            .app_data(web::ThinData(dataset))
            .app_data(web::PayloadConfig::new(25 * 1024 * 1024))
            // This worker's own pool: see db.rs.
            .app_data(web::Data::new(db::worker_pool()))
            .service(
                web::resource("/baseline11")
                    .route(web::get().to(baseline11_get))
                    .route(web::post().to(baseline11_post)),
            )
            .route("/baseline2", web::get().to(baseline2))
            .route("/pipeline", web::get().to(pipeline))
            .route("/echo", web::post().to(echo_body))
            .route("/async-db", web::get().to(db::async_db))
            .route("/fortunes", web::get().to(fortunes::fortunes))
            .route("/delay/{ms}", web::get().to(delay))
            // The Compress middleware wraps only the route whose profile asks
            // for on-the-fly compression (json-comp). Around the whole app it
            // also compressed every static file that has no pre-compressed
            // sibling: the two .woff2 fonts went through brotli on each request.
            .service(
                web::resource("/json/{count}")
                    .wrap(Compress::default())
                    .route(web::get().to(json_endpoint)),
            )
            // actix-files serves from disk per request. `try_compressed()`
            // selects a pre-compressed .br/.gz sibling by Accept-Encoding
            // (framework API — no hand-rolled suffix lookup), falling back to
            // the identity file when no variant exists. Reading per request
            // keeps it freshness-compliant (no permanent in-memory cache).
            .service(Files::new("/static", "/data/static").try_compressed())
    })
    .workers(workers)
    .tcp_nodelay(true)
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
