// The HttpArena entry for Cpeak (https://www.http-arena.com).
//
// Everything here goes through Cpeak's documented API, in its default configuration:
// the router for the paths and their parameters, req.query for the query strings,
// req.chunk() for the request bodies, res.json() for the JSON, Cpeak's own compression
// for json-comp, cpeak::sleep() for async and Cpeak's https option for the TLS tests.

use std::sync::LazyLock;
use std::time::Duration;

use cpeak::{
    json, CompressionOptions, Cpeak, CpeakError, CpeakOptions, CpeakRequest, HttpsOptions,
};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use serde::{Deserialize, Serialize};

// One item of /data/dataset.json
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

#[derive(Deserialize, Serialize, Clone, Copy)]
struct Rating {
    score: i64,
    count: i64,
}

// One item of the /json response: the dataset item, plus its total
#[derive(Serialize)]
struct Item<'a> {
    id: i64,
    name: &'a str,
    category: &'a str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'a [String],
    rating: Rating,
    total: i64,
}

// One row of the items table in Postgres, for /async-db
#[derive(Serialize)]
struct DbItem {
    id: i32,
    name: String,
    category: String,
    price: i32,
    quantity: i32,
    active: bool,
    tags: serde_json::Value,
    rating: DbRating,
}

#[derive(Serialize)]
struct DbRating {
    score: i32,
    count: i32,
}

// What /json and /async-db respond with
#[derive(Serialize)]
struct Items<T> {
    items: Vec<T>,
    count: usize,
}

// The dataset that HttpArena mounts, read once
static DATASET: LazyLock<Vec<DatasetItem>> = LazyLock::new(|| {
    let data = std::fs::read_to_string("/data/dataset.json").unwrap_or_default();
    serde_json::from_str(&data).unwrap_or_default()
});

// Each worker thread has its own event loop, so each one gets its own share of the Postgres
// connections. None when DATABASE_URL isn't set (HttpArena only sets it for the database tests).
thread_local! {
    static POSTGRES: Option<Pool> = postgres();
}

fn postgres() -> Option<Pool> {
    let url = std::env::var("DATABASE_URL").ok()?;
    let max_connections: usize = std::env::var("DATABASE_MAX_CONN")
        .ok()
        .and_then(|max| max.parse().ok())
        .unwrap_or(256);
    let workers = std::thread::available_parallelism().map_or(1, |cores| cores.get());
    let manager = Manager::from_config(
        url.parse().ok()?,
        tokio_postgres::NoTls,
        ManagerConfig {
            recycling_method: RecyclingMethod::Fast,
        },
    );
    Pool::builder(manager)
        .max_size((max_connections / workers).max(1))
        .build()
        .ok()
}

async fn find_items(min: i32, max: i32, limit: i64) -> Option<Items<DbItem>> {
    let client = POSTGRES.with(|pool| pool.clone())?.get().await.ok()?;
    let statement = client
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
             FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
        )
        .await
        .ok()?;
    let rows = client.query(&statement, &[&min, &max, &limit]).await.ok()?;

    let items: Vec<DbItem> = rows
        .iter()
        .map(|row| DbItem {
            id: row.get(0),
            name: row.get(1),
            category: row.get(2),
            price: row.get(3),
            quantity: row.get(4),
            active: row.get(5),
            tags: row.get(6),
            rating: DbRating {
                score: row.get(7),
                count: row.get(8),
            },
        })
        .collect();
    Some(Items {
        count: items.len(),
        items,
    })
}

// A whole number from the query string, like the a in /baseline11?a=13&b=42
fn query_number(req: &CpeakRequest, name: &str, default: i64) -> i64 {
    req.query
        .get(name)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

// The whole body of a request, which arrives in chunks
async fn read_body(req: &mut CpeakRequest) -> Result<Vec<u8>, CpeakError> {
    let mut body = Vec::new();
    while let Some(chunk) = req.chunk().await? {
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

// The key and the certificate that HttpArena mounts for the tests over TLS
fn https_options() -> Option<HttpsOptions> {
    Some(HttpsOptions {
        key: std::fs::read_to_string("/certs/server.key").ok()?,
        cert: std::fs::read_to_string("/certs/server.crt").ok()?,
    })
}

// The app with all its routes, to serve over HTTP (https: None) or over HTTPS
fn app(https: Option<HttpsOptions>) -> Cpeak {
    let mut server = Cpeak::new(CpeakOptions {
        compression: Some(CompressionOptions::default()),
        https,
        ..Default::default()
    });

    // baseline, limited-conn and the latency tests: the sum of the query values
    server.route("get", "/baseline11", async |req, res| {
        let sum = query_number(req, "a", 0) + query_number(req, "b", 0);
        res.set_header("Content-Type", "text/plain")
            .end(sum.to_string())
    });

    // ...plus the number in the body, which comes with a Content-Length or chunked
    server.route("post", "/baseline11", async |req, res| {
        let body = read_body(req).await?;
        let number = String::from_utf8_lossy(&body)
            .trim()
            .parse::<i64>()
            .unwrap_or(0);
        let sum = query_number(req, "a", 0) + query_number(req, "b", 0) + number;
        res.set_header("Content-Type", "text/plain")
            .end(sum.to_string())
    });

    // pipelined
    server.route("get", "/pipeline", async |_req, res| {
        res.set_header("Content-Type", "text/plain").end("ok")
    });

    // async: wait for as long as the path says, without holding up the worker thread
    server.route("get", "/delay/:ms", async |req, res| {
        let ms: u64 = req.params["ms"].parse().unwrap_or(0);
        if ms > 0 {
            cpeak::sleep(Duration::from_millis(ms)).await;
        }
        res.set_header("Content-Type", "text/plain")
            .end(ms.to_string())
    });

    // json-comp and json-tls: the first `count` items of the dataset, each with its total.
    // Cpeak compresses the response when the client accepts it.
    server.route("get", "/json/:count", async |req, res| {
        let count = req.params["count"]
            .parse::<usize>()
            .unwrap_or(0)
            .min(DATASET.len());
        let m = query_number(req, "m", 1);

        let items = DATASET[..count]
            .iter()
            .map(|item| Item {
                id: item.id,
                name: &item.name,
                category: &item.category,
                price: item.price,
                quantity: item.quantity,
                active: item.active,
                tags: &item.tags,
                rating: item.rating,
                total: item.price * item.quantity * m,
            })
            .collect();

        res.json(Items { items, count })
    });

    // 8gbit: send the body back as it came
    server.route("post", "/echo", async |req, res| {
        let body = read_body(req).await?;
        res.set_header("Content-Type", "application/octet-stream")
            .end(body)
    });

    // async-db: a range query on Postgres
    server.route("get", "/async-db", async |req, res| {
        let min = query_number(req, "min", 10) as i32;
        let max = query_number(req, "max", 50) as i32;
        let limit = query_number(req, "limit", 50).clamp(1, 50);

        match find_items(min, max, limit).await {
            Some(items) => res.json(items),
            // Postgres can't be reached
            None => res.json(json!({ "items": [], "count": 0 })),
        }
    });

    server.handle_err(async |error, _req, res| {
        if let Some(status) = error.status {
            return res.status(status).json(json!({ "error": error.message }));
        }
        eprintln!("{error:?}");
        res.status(500)
            .json(json!({ "error": "Sorry, something unexpected happened on our side." }))
    });

    server
}

fn main() {
    let http = app(None).listen(8080, || {});
    // The same app over HTTPS, for json-tls and 8gbit
    let _https = https_options().map(|https| app(Some(https)).listen(8081, || {}));

    http.wait();
}
