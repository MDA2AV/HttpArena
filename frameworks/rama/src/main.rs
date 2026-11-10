use std::{sync::Arc, time::Duration};

use rama::{
    Layer,
    crypto::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject},
    http::{
        layer::{compression::CompressionLayer, error_handling::ErrorHandlerLayer},
        server::HttpServer,
        service::{
            fs::ServeDir,
            web::{
                Router,
                extract::{Bytes, Path, Query, State},
                response::Json,
            },
        },
        ws::handshake::server::WebSocketAcceptor,
    },
    layer::ConsumeErrLayer,
    rt::Executor,
    tcp::server::TcpListener,
    tls::{
        rustls::server::TlsAcceptorLayer,
        server::{ServerAuthData, TlsServerConfig},
    },
};
use serde::{Deserialize, Serialize};

const DATASET_PATH: &str = "/data/dataset.json";
const STATIC_DIR: &str = "/data/static";
const CERT_PATH: &str = "/certs/server.crt";
const KEY_PATH: &str = "/certs/server.key";

#[derive(Deserialize)]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize)]
struct DatasetItem {
    id: i64,
    name: Box<str>,
    category: Box<str>,
    price: i64,
    quantity: i64,
    active: bool,
    tags: Box<[Box<str>]>,
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
    tags: &'a [Box<str>],
    rating: ProcessedRating,
    total: i64,
}

#[derive(Serialize)]
struct JsonResponse<'a> {
    items: Vec<ProcessedItem<'a>>,
    count: usize,
}

#[derive(Deserialize)]
struct SumQuery {
    a: Option<i64>,
    b: Option<i64>,
}

#[derive(Deserialize)]
struct JsonQuery {
    m: Option<i64>,
}

#[derive(Deserialize)]
struct JsonPath {
    count: usize,
}

#[derive(Deserialize)]
struct DelayPath {
    ms: u64,
}

type Dataset = &'static [DatasetItem];

fn load_dataset() -> Dataset {
    let items: Vec<DatasetItem> = std::fs::read(DATASET_PATH)
        .ok()
        .and_then(|raw| serde_json::from_slice(&raw).ok())
        .unwrap_or_default();
    // leaked once so responses borrow the items instead of cloning them
    Box::leak(items.into_boxed_slice())
}

fn sum(query: &SumQuery) -> i64 {
    query.a.unwrap_or(0) + query.b.unwrap_or(0)
}

async fn baseline_get(Query(query): Query<SumQuery>) -> String {
    sum(&query).to_string()
}

async fn baseline_post(Query(query): Query<SumQuery>, Bytes(body): Bytes) -> String {
    let body = std::str::from_utf8(&body)
        .ok()
        .and_then(|s| s.trim().parse::<i64>().ok())
        .unwrap_or(0);
    (sum(&query) + body).to_string()
}

async fn delay(Path(DelayPath { ms }): Path<DelayPath>) -> String {
    if ms > 0 {
        tokio::time::sleep(Duration::from_millis(ms)).await;
    }
    ms.to_string()
}

async fn json(
    State(dataset): State<Dataset>,
    Path(JsonPath { count }): Path<JsonPath>,
    Query(JsonQuery { m }): Query<JsonQuery>,
) -> Json<JsonResponse<'static>> {
    let m = m.unwrap_or(1);
    let items: Vec<_> = dataset[..count.min(dataset.len())]
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
    let count = items.len();
    Json(JsonResponse { items, count })
}

async fn echo(Bytes(body): Bytes) -> rama::bytes::Bytes {
    body
}

fn load_tls_config() -> Option<TlsServerConfig> {
    let cert_chain = CertificateDer::pem_file_iter(CERT_PATH)
        .ok()?
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    let key = PrivateKeyDer::from_pem_file(KEY_PATH).ok()?;
    Some(TlsServerConfig::new().with_server_auth(ServerAuthData::new(cert_chain, key)))
}

#[tokio::main]
async fn main() {
    let router = Router::new_with_state(load_dataset())
        .with_get("/pipeline", "ok")
        .with_get("/baseline11", baseline_get)
        .with_post("/baseline11", baseline_post)
        .with_get("/baseline2", baseline_get)
        .with_get("/delay/{ms}", delay)
        .with_get("/json/{count}", json)
        .with_post("/echo", echo)
        .with_get(
            "/ws",
            ConsumeErrLayer::trace_as_debug()
                .into_layer(WebSocketAcceptor::new().into_echo_service()),
        )
        .with_endpoint_service(
            "/static",
            ServeDir::new(STATIC_DIR)
                .with_precompressed_br()
                .with_precompressed_gzip(),
        );
    let app = Arc::new((CompressionLayer::new(), ErrorHandlerLayer::new()).into_layer(router));

    let exec = Executor::default();
    let h1 = HttpServer::new_http1(exec.clone()).service(app.clone());
    let h2 = HttpServer::new_h2(exec.clone()).service(app);
    let bind = async |addr: &str| {
        TcpListener::bind_address(addr, exec.clone())
            .await
            .expect("bind tcp listener")
    };

    // One protocol per port: 8080 HTTP/1.1 and WebSocket, 8082 h2c with prior knowledge.
    let mut servers = vec![
        tokio::spawn(bind("0.0.0.0:8080").await.serve(h1.clone())),
        tokio::spawn(bind("0.0.0.0:8082").await.serve(h2.clone())),
    ];

    // TLS listeners only exist when the harness mounts the certificates:
    // 8081 HTTP/1.1 over TLS, 8443 HTTP/2 over TLS.
    if let Some(tls) = load_tls_config() {
        let h1_tls = TlsAcceptorLayer::new(tls.clone().with_alpn_http_1()).into_layer(h1);
        let h2_tls = TlsAcceptorLayer::new(tls.with_alpn_http_2()).into_layer(h2);
        servers.push(tokio::spawn(bind("0.0.0.0:8081").await.serve(h1_tls)));
        servers.push(tokio::spawn(bind("0.0.0.0:8443").await.serve(h2_tls)));
    }

    for server in servers {
        let _ = server.await;
    }
}
