use std::collections::HashMap;
use std::net::SocketAddr;

use socket2::{Domain, Protocol, Socket, Type};

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::routing::{get, post};
use axum::{Json, Router};
use axum_server::tls_rustls::RustlsConfig;
use serde::{Deserialize, Serialize};
use tower_http::compression::CompressionLayer;

const MAX_BODY: usize = 25 * 1024 * 1024;

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
struct ProcessedRating {
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
    rating: ProcessedRating,
    total: i64,
}

#[derive(Serialize)]
struct ProcessResponse<'a> {
    items: Vec<ProcessedItem<'a>>,
    count: usize,
}

#[derive(Deserialize)]
struct JsonParams {
    m: Option<i64>,
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

async fn pipeline() -> &'static str {
    "ok"
}

async fn baseline11(Query(params): Query<HashMap<String, String>>, body: String) -> String {
    let mut sum: i64 = params
        .values()
        .filter_map(|value| value.parse::<i64>().ok())
        .sum();
    if let Ok(n) = body.trim().parse::<i64>() {
        sum += n;
    }
    sum.to_string()
}

async fn json_items(
    State(dataset): State<&'static [DatasetItem]>,
    Path(count): Path<usize>,
    Query(params): Query<JsonParams>,
) -> Json<ProcessResponse<'static>> {
    let count = count.min(dataset.len());
    let m = params.m.unwrap_or(1);

    let items = dataset[..count]
        .iter()
        .map(|item| ProcessedItem {
            id: item.id,
            name: &item.name,
            category: &item.category,
            price: item.price,
            quantity: item.quantity,
            active: item.active,
            tags: &item.tags,
            rating: ProcessedRating {
                score: item.rating.score,
                count: item.rating.count,
            },
            total: item.price * item.quantity * m,
        })
        .collect();

    Json(ProcessResponse { items, count })
}

// Echo: axum has already collected the body (chunked or not) into Bytes, so
// handing it straight back is the whole handler and costs no extra copy.
async fn echo_body(body: Bytes) -> Bytes {
    body
}

/// A listening socket with SO_REUSEPORT set, so several of them can share one
/// port and the kernel spreads inbound connections across their accept queues.
fn reuseport_listener(addr: SocketAddr) -> std::net::TcpListener {
    let sock = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).unwrap();
    sock.set_reuse_address(true).unwrap();
    sock.set_reuse_port(true).unwrap();
    sock.set_nonblocking(true).unwrap();
    sock.bind(&addr.into()).unwrap();
    sock.listen(4096).unwrap();
    sock.into()
}

#[tokio::main]
async fn main() {
    // Leaked once at startup so handlers can borrow the items instead of
    // cloning every string into the response.
    let dataset: &'static [DatasetItem] = Box::leak(load_dataset().into_boxed_slice());

    let app = Router::new()
        .route("/pipeline", get(pipeline))
        .route("/baseline11", get(baseline11).post(baseline11))
        .route("/json/{count}", get(json_items))
        .route("/echo", post(echo_body))
        .layer(CompressionLayer::new())
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .with_state(dataset);

    // json-tls on 8081, served by the same Router. axum-server is axum's own
    // TLS companion (it is what the axum tls-rustls example uses), so the
    // accept loop is the framework's rather than hand-rolled here. The harness
    // only mounts /certs for the TLS profiles, hence the guard.
    let cert = std::path::Path::new("/certs/server.crt");
    let key = std::path::Path::new("/certs/server.key");
    if cert.exists() && key.exists() {
        // ring rather than aws-lc-rs: same TLS, no C toolchain in the build image
        rustls::crypto::ring::default_provider().install_default().ok();
        let tls_config = RustlsConfig::from_pem_file(cert, key).await.unwrap();
        let tls_app = app.clone();
        tokio::spawn(async move {
            axum_server::bind_rustls("0.0.0.0:8081".parse().unwrap(), tls_config)
                .serve(tls_app.into_make_service())
                .await
                .unwrap();
        });
    }

    // One listener per core rather than one for the process.
    //
    // axum::serve drives a single accept task, so every inbound connection is
    // accepted by one thread no matter how many the runtime has. That costs
    // nothing while connections are held, and everything once they churn:
    // measured on the bench box, this entry served json (gcannon -r 25, a new
    // connection every 25 requests) at 216K rps on 1526% CPU, and json-tls
    // (wrk, connections held) at 992K on 6313% -- same handler, same payloads,
    // same machine, four times the CPU purely because nothing was reconnecting.
    // A single accept loop looks worse the more cores it is given.
    //
    // SO_REUSEPORT gives each accept loop its own queue and lets the kernel
    // balance across them, which is what bun, go-fasthttp, hono-bun and fletch
    // already do here.
    let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    let addr: SocketAddr = "0.0.0.0:8080".parse().unwrap();
    let mut tasks = Vec::new();
    for _ in 0..workers {
        let app = app.clone();
        let std_listener = reuseport_listener(addr);
        tasks.push(tokio::spawn(async move {
            let l = tokio::net::TcpListener::from_std(std_listener).unwrap();
            axum::serve(l, app).await.unwrap();
        }));
    }
    for t in tasks { let _ = t.await; }
}
