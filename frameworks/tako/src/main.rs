use std::time::Duration;

use serde::{Deserialize, Serialize};
use tako::extractors::json::Json;
use tako::extractors::path::Path;
use tako::extractors::query::Query;
use tako::extractors::state::State;
use tako::plugins::compression::CompressionBuilder;
use tako::router::Router;
use tako::r#static::{PrecompressedPolicy, ServeDir};
use tako::types::Request;
use tako::{Bytes, PerThreadConfig, Server, TlsCert};
use tokio::net::TcpListener;

const CERT: &str = "/certs/server.crt";
const KEY: &str = "/certs/server.key";

type Dataset = &'static [Item];

#[derive(Deserialize)]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize)]
struct Item {
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

#[derive(Serialize)]
struct ItemOut {
    id: i64,
    name: &'static str,
    category: &'static str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'static [String],
    rating: RatingOut,
    total: i64,
}

#[derive(Serialize)]
struct Items {
    items: Vec<ItemOut>,
    count: usize,
}

#[derive(Deserialize)]
struct Operands {
    a: i64,
    b: i64,
}

#[derive(Deserialize)]
struct Multiplier {
    m: i64,
}

async fn pipeline() -> &'static str {
    "ok"
}

async fn baseline_get(Query(q): Query<Operands>) -> String {
    (q.a + q.b).to_string()
}

async fn baseline_post(Query(q): Query<Operands>, body: Bytes) -> String {
    let n: i64 = std::str::from_utf8(&body)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    (q.a + q.b + n).to_string()
}

async fn delay(Path(ms): Path<u64>) -> String {
    tokio::time::sleep(Duration::from_millis(ms)).await;
    ms.to_string()
}

async fn json(
    State(dataset): State<Dataset>,
    Path(count): Path<usize>,
    Query(Multiplier { m }): Query<Multiplier>,
) -> Json<Items> {
    let dataset: Dataset = *dataset;
    let items: Vec<ItemOut> = dataset
        .iter()
        .take(count)
        .map(|item| ItemOut {
            id: item.id,
            name: &item.name,
            category: &item.category,
            price: item.price,
            quantity: item.quantity,
            active: item.active,
            tags: &item.tags,
            rating: RatingOut {
                score: item.rating.score,
                count: item.rating.count,
            },
            total: item.price * item.quantity * m,
        })
        .collect();
    Json(Items {
        count: items.len(),
        items,
    })
}

async fn echo(body: Bytes) -> Bytes {
    body
}

fn router(dataset: Dataset) -> Router {
    let files = ServeDir::builder("/data")
        .precompressed(PrecompressedPolicy::both())
        .build();
    let mut router = Router::new();
    router.with_state(dataset);
    router.get("/pipeline", pipeline);
    router.get("/baseline11", baseline_get);
    router.post("/baseline11", baseline_post);
    router.get("/delay/{ms}", delay);
    router
        .get("/json/{count}", json)
        .plugin(CompressionBuilder::new().build());
    router.post("/echo", echo);
    router.get("/static/{*path}", move |req: Request| async move {
        files.handle(req).await
    });
    router
}

#[tokio::main]
async fn serve_tls(dataset: Dataset) {
    let listener = TcpListener::bind("0.0.0.0:8081").await.expect("bind :8081");
    let server = Server::builder().tls(TlsCert::pem_paths(CERT, KEY)).build();
    if let Err(error) = server.spawn_tls(listener, router(dataset)).result().await {
        eprintln!("TLS listener failed: {error}");
        std::process::exit(1);
    }
}

fn main() -> std::io::Result<()> {
    let items: Vec<Item> = serde_json::from_slice(&std::fs::read("/data/dataset.json")?)?;
    let dataset: Dataset = Box::leak(items.into_boxed_slice());
    if std::path::Path::new(CERT).exists() && std::path::Path::new(KEY).exists() {
        std::thread::spawn(move || serve_tls(dataset));
    }
    tako::serve_per_thread("0.0.0.0:8080", router(dataset), PerThreadConfig::default())
}
