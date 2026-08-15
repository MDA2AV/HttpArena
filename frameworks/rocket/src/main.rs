#[macro_use]
extern crate rocket;

use std::collections::HashMap;

use rocket::data::{Data, ToByteUnit};
use rocket::serde::json::Json;
use rocket::serde::{Deserialize, Serialize};
use rocket::tokio::io::sink;
use rocket::State;

const MAX_BODY_MIB: usize = 25;

#[derive(Deserialize)]
#[serde(crate = "rocket::serde")]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize)]
#[serde(crate = "rocket::serde")]
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
#[serde(crate = "rocket::serde")]
struct ProcessedRating {
    score: i64,
    count: i64,
}

#[derive(Serialize)]
#[serde(crate = "rocket::serde")]
struct ProcessedItem {
    id: i64,
    name: &'static str,
    category: &'static str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'static [String],
    rating: ProcessedRating,
    total: i64,
}

#[derive(Serialize)]
#[serde(crate = "rocket::serde")]
struct ProcessResponse {
    items: Vec<ProcessedItem>,
    count: usize,
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(path) {
        Ok(data) => rocket::serde::json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn sum_params(params: &HashMap<String, String>) -> i64 {
    params.values().filter_map(|v| v.parse::<i64>().ok()).sum()
}

#[get("/pipeline")]
fn pipeline() -> &'static str {
    "ok"
}

#[get("/baseline11?<params..>")]
fn baseline11_get(params: HashMap<String, String>) -> String {
    sum_params(&params).to_string()
}

#[post("/baseline11?<params..>", data = "<body>")]
fn baseline11_post(params: HashMap<String, String>, body: String) -> String {
    let mut sum = sum_params(&params);
    if let Ok(n) = body.trim().parse::<i64>() {
        sum += n;
    }
    sum.to_string()
}

#[get("/json/<count>?<m>")]
fn json_items(
    count: usize,
    m: Option<i64>,
    dataset: &State<&'static [DatasetItem]>,
) -> Json<ProcessResponse> {
    let count = count.min(dataset.len());
    let m = m.unwrap_or(1);

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

#[post("/upload", data = "<data>")]
async fn upload(data: Data<'_>) -> String {
    match data.open(MAX_BODY_MIB.mebibytes()).stream_to(sink()).await {
        Ok(written) => written.to_string(),
        Err(_) => "0".to_string(),
    }
}

#[launch]
fn rocket() -> _ {
    // Leaked once at startup so handlers borrow the items instead of cloning
    // every string into the response.
    let dataset: &'static [DatasetItem] = Box::leak(load_dataset().into_boxed_slice());

    rocket::build().manage(dataset).mount(
        "/",
        routes![pipeline, baseline11_get, baseline11_post, json_items, upload],
    )
}
