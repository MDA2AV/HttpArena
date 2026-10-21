mod db;

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tako::extractors::json::Json;
use tako::extractors::path::Path;
use tako::extractors::query::Query;
use tako::extractors::state::State;
use tako::plugins::compression::CompressionBuilder;
use tako::responder::Responder;
use tako::router::Router;
use tako::r#static::{PrecompressedPolicy, ServeDir};
use tako::types::{BoxError, Request};
use tako::ws::TakoWs;
use tako::{Bytes, PerThreadConfig, Server, TlsCert};
use tokio::net::TcpListener;

const CERT: &str = "/certs/server.crt";
const KEY: &str = "/certs/server.key";

type AppRef = &'static App;

struct App {
    dataset: Vec<Item>,
    db: db::Db,
}

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
    m: Option<i64>,
}

async fn pipeline() -> &'static str {
    "ok"
}

async fn sum(Query(q): Query<Operands>) -> String {
    (q.a + q.b).to_string()
}

async fn sum_with_body(Query(q): Query<Operands>, body: Bytes) -> String {
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
    State(app): State<AppRef>,
    Path(count): Path<usize>,
    Query(Multiplier { m }): Query<Multiplier>,
) -> Json<Items> {
    let app: AppRef = *app;
    let m = m.unwrap_or(1);
    let items: Vec<ItemOut> = app
        .dataset
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

async fn ws_echo(req: Request) -> impl Responder {
    TakoWs::new(req, |mut ws| async move {
        while let Some(Ok(message)) = ws.next().await {
            if (message.is_text() || message.is_binary()) && ws.send(message).await.is_err() {
                break;
            }
        }
    })
}

fn router(app: AppRef) -> Router {
    let files = ServeDir::builder("/data")
        .precompressed(PrecompressedPolicy::both())
        .build();
    let mut router = Router::new();
    router.with_state(app);
    router.get("/pipeline", pipeline);
    router.get("/baseline11", sum);
    router.post("/baseline11", sum_with_body);
    router.get("/baseline2", sum);
    router.get("/delay/{ms}", delay);
    router
        .get("/json/{count}", json)
        .plugin(CompressionBuilder::new().build());
    router.post("/echo", echo);
    router.get("/static/{*path}", move |req: Request| async move {
        files.handle(req).await
    });
    router.get("/ws", ws_echo);
    router.get("/async-db", db::price_range);
    router.get("/public/baseline", sum);
    router
        .get("/public/json/{count}", json)
        .plugin(CompressionBuilder::new().build());
    router.get("/api/items/{id}", db::read_item);
    router.post("/api/items/{id}", db::write_item);
    router.get("/api/me", db::me);
    router
}

#[tokio::main]
async fn serve(app: AppRef) -> Result<(), BoxError> {
    let server = Server::builder().tls(TlsCert::pem_paths(CERT, KEY)).build();
    let h2c = TcpListener::bind("0.0.0.0:8082").await?;
    let mut handles = vec![server.try_spawn_h2c(h2c, router(app))?];
    if std::path::Path::new(CERT).exists() && std::path::Path::new(KEY).exists() {
        let h1 = TcpListener::bind("0.0.0.0:8081").await?;
        let h2 = TcpListener::bind("0.0.0.0:8443").await?;
        handles.push(server.try_spawn_tls(h1, router(app))?);
        handles.push(server.try_spawn_tls(h2, router(app))?);
        handles.push(server.try_spawn_h3("0.0.0.0:8443", router(app))?);
    }
    for handle in handles {
        handle.result().await?;
    }
    Ok(())
}

fn main() -> std::io::Result<()> {
    let dataset = serde_json::from_slice(&std::fs::read("/data/dataset.json")?)?;
    let app: AppRef = Box::leak(Box::new(App {
        dataset,
        db: db::Db::from_env(),
    }));
    std::thread::spawn(move || {
        if let Err(error) = serve(app) {
            eprintln!("listener failed: {error}");
            std::process::exit(1);
        }
    });
    tako::serve_per_thread("0.0.0.0:8080", router(app), PerThreadConfig::default())
}
