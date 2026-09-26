//! Toxi entry for HTTP Arena: baseline, pipelined, limited-conn, json-comp.
//!
//! Profiles served on port 8080. The JSON dataset loads once at startup
//! from `DATASET_PATH` (`/data/dataset.json` on the arena runners).

use flate2::write::GzEncoder;
use flate2::Compression;
use http_body_util::{BodyExt, Full};
use std::io::Write;
use std::sync::Arc;
use toxi::prelude::*;

#[derive(serde::Deserialize, Clone)]
struct Item {
    id: i64,
    name: String,
    category: String,
    price: i64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: serde_json::Value,
}

#[derive(serde::Deserialize)]
struct CountPath {
    count: usize,
}

#[derive(serde::Deserialize)]
struct SumQuery {
    a: Option<i64>,
    b: Option<i64>,
}

#[derive(serde::Deserialize)]
struct DelayPath {
    ms: u64,
}

#[derive(serde::Deserialize)]
struct Multiplier {
    #[serde(default = "default_m")]
    m: i64,
}

fn default_m() -> i64 {
    1
}

fn plain(text: String) -> Result<Response> {
    Ok(Response::text(text))
}

async fn baseline_get(Query(q): Query<SumQuery>) -> Result<Response> {
    plain((q.a.unwrap_or(0) + q.b.unwrap_or(0)).to_string())
}

async fn baseline_post(
    Query(q): Query<SumQuery>,
    Body(body): Body<Vec<u8>>,
) -> Result<Response> {
    // Mirrors the reference entries: the body carries a JSON integer.
    let n: i64 = serde_json::from_slice(&body).unwrap_or(0);
    plain((q.a.unwrap_or(0) + q.b.unwrap_or(0) + n).to_string())
}

async fn pipeline(_req: Request) -> Result<Response> {
    plain("ok".to_string())
}

async fn delay(Path(ms): Path<DelayPath>) -> Result<Response> {
    if ms.ms > 0 {
        tokio::time::sleep(std::time::Duration::from_millis(ms.ms)).await;
    }
    plain(ms.ms.to_string())
}

async fn echo_bytes(Body(body): Body<Vec<u8>>) -> Result<Response> {
    let res = http::Response::builder()
        .header(http::header::CONTENT_TYPE, "application/octet-stream")
        .body(
            Full::new(bytes::Bytes::from(body))
                .map_err(|e| match e {})
                .boxed(),
        )
        .map_err(|e| Error::InternalServerError(e.to_string()))?;
    Ok(Response::new(res))
}

use toxi::extract::FromRequest;

struct AcceptsGzip(bool);

impl FromRequest for AcceptsGzip {
    async fn from_request(req: &mut toxi::ToxiRequest) -> toxi::Result<Self> {
        Ok(Self(
            req.headers()
                .get(http::header::ACCEPT_ENCODING)
                .and_then(|v| v.to_str().ok())
                .map(|v| v.contains("gzip"))
                .unwrap_or(false),
        ))
    }
}

async fn json_dataset(
    Path(path): Path<CountPath>,
    Query(m): Query<Multiplier>,
    AcceptsGzip(wants_gzip): AcceptsGzip,
    State(items): State<Arc<Vec<Item>>>,
) -> Result<Response> {
    let n = path.count.min(items.len());
    let entries: Vec<serde_json::Value> = items[..n]
        .iter()
        .map(|item| {
            serde_json::json!({
                "id": item.id,
                "name": item.name,
                "category": item.category,
                "price": item.price,
                "quantity": item.quantity,
                "active": item.active,
                "tags": item.tags,
                "rating": item.rating,
                "total": item.price * item.quantity * m.m,
            })
        })
        .collect();
    let body = serde_json::to_vec(&serde_json::json!({
        "items": entries,
        "count": n,
    }))
    .map_err(|e| Error::InternalServerError(e.to_string()))?;

    if !wants_gzip {
        return Ok(Response::json(serde_json::from_slice::<serde_json::Value>(
            &body,
        ).map_err(|e| Error::InternalServerError(e.to_string()))?));
    }

    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(&body)
        .map_err(|e| Error::InternalServerError(e.to_string()))?;
    let gz = encoder
        .finish()
        .map_err(|e| Error::InternalServerError(e.to_string()))?;

    let res = http::Response::builder()
        .header(http::header::CONTENT_TYPE, "application/json")
        .header(http::header::CONTENT_ENCODING, "gzip")
        .body(
            Full::new(bytes::Bytes::from(gz))
                .map_err(|e| match e {})
                .boxed(),
        )
        .map_err(|e| Error::InternalServerError(e.to_string()))?;
    Ok(Response::new(res))
}

fn load_dataset() -> Vec<Item> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    let data = std::fs::read_to_string(&path).expect("dataset readable");
    serde_json::from_str(&data).expect("dataset parses")
}

#[tokio::main]
async fn main() -> Result<()> {
    let items = Arc::new(load_dataset());
    let mut router = Router::new();
    router.with_state(items);
    router.get("/baseline11", baseline_get);
    router.post("/baseline11", baseline_post);
    router.get("/pipeline", pipeline);
    router.get("/delay/:ms", delay);
    router.post("/echo", echo_bytes);
    router.get("/json/:count", json_dataset);

    // TLS profiles (json-tls, 8gbit) serve the same router on 8081 with
    // HTTP/1.1 only. Paths default to the harness mounts and accept
    // TLS_CERT/TLS_KEY overrides for local validation.
    let cert_path =
        std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key_path =
        std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    let cert = std::path::Path::new(&cert_path);
    let key = std::path::Path::new(&key_path);
    if cert.exists() && key.exists() {
        let tls_router = router.clone();
        tokio::spawn(async move {
            let tls = toxi_core::tls::TlsConfig::new(cert_path, key_path);
            let addr: std::net::SocketAddr = "0.0.0.0:8081".parse().unwrap();
            println!("toxi-arena https listening on {addr}");
            toxi_core::tls::SecureServer::new(tls_router)
                .with_tls(tls)
                .with_http_version(toxi_core::HttpVersion::Http1)
                .listen(addr)
                .await
        });
    }

    let addr: std::net::SocketAddr = "0.0.0.0:8080".parse().unwrap();
    println!("toxi-arena listening on {addr}");
    Server::new(router).listen(addr).await
}
