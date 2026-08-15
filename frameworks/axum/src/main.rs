use std::collections::HashMap;

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::routing::{get, post};
use axum::{Json, Router};
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

async fn upload(body: Bytes) -> String {
    body.len().to_string()
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
        .route("/upload", post(upload))
        .layer(CompressionLayer::new())
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .with_state(dataset);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
