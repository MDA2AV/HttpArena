
use std::io::Write;

use ntex::util::Bytes;
use ntex::web::{self, middleware, App, HttpRequest, HttpResponse, HttpServer};
use serde::{Deserialize, Serialize};

const MAX_BODY: usize = 64 * 1024 * 1024;

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
struct OutRating {
    score: i64,
    count: i64,
}

// Field order is the wire order: id..rating then the computed total.
#[derive(Serialize)]
struct OutItem<'a> {
    id: i64,
    name: &'a str,
    category: &'a str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'a [String],
    rating: OutRating,
    total: i64,
}

#[derive(Serialize)]
struct OutList<'a> {
    items: Vec<OutItem<'a>>,
    count: usize,
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

/// Sum of every query parameter whose value parses as an integer; a
/// non-numeric one is skipped rather than failing the request.
fn sum_query(query: &str) -> i64 {
    let mut total = 0i64;
    for pair in query.split('&') {
        if let Some((_, value)) = pair.split_once('=') {
            if let Ok(n) = value.trim().parse::<i64>() {
                total += n;
            }
        }
    }
    total
}

async fn baseline11(req: HttpRequest, body: Bytes) -> HttpResponse {
    let mut total = sum_query(req.query_string());
    if let Ok(text) = std::str::from_utf8(&body) {
        if let Ok(n) = text.trim().parse::<i64>() {
            total += n;
        }
    }
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(total.to_string())
}

fn build_json(dataset: &[DatasetItem], count: usize, m: i64) -> Vec<u8> {
    let n = count.min(dataset.len());
    let items = dataset[..n]
        .iter()
        .map(|d| OutItem {
            id: d.id,
            name: &d.name,
            category: &d.category,
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: &d.tags,
            rating: OutRating { score: d.rating.score, count: d.rating.count },
            total: d.price * d.quantity * m,
        })
        .collect();
    serde_json::to_vec(&OutList { items, count: n }).unwrap_or_default()
}

fn accepts(req: &HttpRequest, token: &str) -> bool {
    req.headers()
        .get("accept-encoding")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.to_ascii_lowercase().contains(token))
        .unwrap_or(false)
}

async fn json_items(
    req: HttpRequest,
    path: web::types::Path<usize>,
    dataset: web::types::State<&'static [DatasetItem]>,
) -> HttpResponse {
    let m = req
        .query_string()
        .split('&')
        .find_map(|p| p.strip_prefix("m="))
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(1);
    let body = build_json(&dataset, path.into_inner(), m);

    // json-comp negotiates by hand: ntex's Compress middleware would also cover
    // it, but it re-compresses per request at a fixed level and the profile
    // asks for level 1, so the encoder is driven directly here.
    if accepts(&req, "gzip") {
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(1));
        if enc.write_all(&body).is_ok() {
            if let Ok(compressed) = enc.finish() {
                return HttpResponse::Ok()
                    .content_type("application/json")
                    .header("Content-Encoding", "gzip")
                    .header("Vary", "Accept-Encoding")
                    .body(compressed);
            }
        }
    }
    HttpResponse::Ok().content_type("application/json").body(body)
}

async fn upload(body: Bytes) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(body.len().to_string())
}

fn routes(cfg: &mut web::ServiceConfig, dataset: &'static [DatasetItem]) {
    cfg.state(dataset)
        .state(web::types::PayloadConfig::new(MAX_BODY))
        .service(
            web::resource("/baseline11")
                .route(web::get().to(baseline11))
                .route(web::post().to(baseline11)),
        )
        .service(web::resource("/json/{count}").route(web::get().to(json_items)))
        .service(web::resource("/upload").route(web::post().to(upload)));
}

#[ntex::main]
async fn main() -> std::io::Result<()> {
    // Leaked once at startup so handlers borrow the items instead of cloning
    // every string into each response.
    let dataset: &'static [DatasetItem] = Box::leak(load_dataset().into_boxed_slice());

    let mut server = HttpServer::new(move || {
        App::new()
            .wrap(middleware::Logger::default().exclude("/"))
            .configure(|cfg| routes(cfg, dataset))
    })
    .backlog(4096)
    .bind("0.0.0.0:8080")?;

    // json-tls on 8081. The harness mounts /certs only for the TLS profiles,
    // so a missing pair leaves the listener down rather than aborting startup.
    let cert = std::path::Path::new("/certs/server.crt");
    let key = std::path::Path::new("/certs/server.key");
    if cert.exists() && key.exists() {
        // ring rather than aws-lc-rs: same TLS, no C toolchain in the build image
        let _ = rustls::crypto::ring::default_provider().install_default();
        let certs: Vec<_> = rustls_pemfile::certs(&mut std::io::BufReader::new(
            std::fs::File::open(cert)?,
        ))
        .collect::<Result<_, _>>()?;
        let private = rustls_pemfile::private_key(&mut std::io::BufReader::new(
            std::fs::File::open(key)?,
        ))?
        .expect("no private key in /certs/server.key");
        let mut tls = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certs, private)
            .expect("bad certificate/key pair");
        // 8081 is the HTTP/1.1 port; h2 lives on 8443, so never offer it here.
        tls.alpn_protocols = vec![b"http/1.1".to_vec()];
        server = server.bind_rustls("0.0.0.0:8081", tls)?;
    }

    server.run().await
}
