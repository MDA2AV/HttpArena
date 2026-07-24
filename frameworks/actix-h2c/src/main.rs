fn cgroup_cpus() -> usize {
    std::fs::read_to_string("/sys/fs/cgroup/cpu.max")
        .ok()
        .and_then(|s| {
            let mut parts = s.trim().split(' ');
            let quota = parts.next()?;
            if quota == "max" { return None; }
            let period: usize = parts.next()?.parse().ok()?;
            let q: usize = quota.parse().ok()?;
            let cpus = q / period;
            if cpus >= 1 { Some(cpus) } else { None }
        })
        .unwrap_or_else(num_cpus::get)
}

use actix_web::dev::{Service, ServiceRequest, ServiceResponse};
use actix_web::http::header::{HeaderValue, SERVER};
use actix_web::http::Version;
use actix_web::{web, App, HttpResponse, HttpServer};
use futures_util::future::{ready, Either};
use serde::{Deserialize, Serialize};
use std::io;

static SERVER_HDR: HeaderValue = HeaderValue::from_static("actix");

#[derive(Deserialize)]
struct BaselineQuery {
    a: Option<i64>,
    b: Option<i64>,
}

#[derive(Deserialize)]
struct JsonQuery {
    m: Option<i64>,
}

#[derive(Deserialize, Clone)]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize, Clone)]
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

#[derive(Serialize, Clone)]
struct RatingOut {
    score: i64,
    count: i64,
}

#[derive(Serialize, Clone)]
struct ProcessedItem {
    id: i64,
    name: String,
    category: String,
    price: i64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: RatingOut,
    total: i64,
}

#[derive(Serialize)]
struct JsonResponse {
    items: Vec<ProcessedItem>,
    count: usize,
}

struct AppState {
    dataset: Vec<DatasetItem>,
}

fn build_json_body(dataset: &[DatasetItem], count: usize, m: i64) -> Vec<u8> {
    let count = count.min(dataset.len());
    let items: Vec<ProcessedItem> = dataset[..count]
        .iter()
        .map(|d| ProcessedItem {
            id: d.id,
            name: d.name.clone(),
            category: d.category.clone(),
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: d.tags.clone(),
            rating: RatingOut {
                score: d.rating.score,
                count: d.rating.count,
            },
            total: d.price * d.quantity * m,
        })
        .collect();
    let resp = JsonResponse { count, items };
    serde_json::to_vec(&resp).unwrap_or_default()
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(&path) {
        Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

async fn baseline2(query: web::Query<BaselineQuery>) -> HttpResponse {
    let sum = query.a.unwrap_or(0) + query.b.unwrap_or(0);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type("text/plain")
        .body(sum.to_string())
}

async fn json_endpoint(
    state: web::Data<AppState>,
    path: web::Path<usize>,
    query: web::Query<JsonQuery>,
) -> HttpResponse {
    let count = path.into_inner().min(state.dataset.len());
    let m = query.m.unwrap_or(1);
    let body = build_json_body(&state.dataset, count, m);
    HttpResponse::Ok()
        .insert_header((SERVER, SERVER_HDR.clone()))
        .content_type("application/json")
        .body(body)
}

#[actix_web::main]
async fn main() -> io::Result<()> {
    let dataset = load_dataset();
    let state = web::Data::new(AppState { dataset });
    let workers = cgroup_cpus();

    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            // bind_auto_h2c accepts H1 and h2c on the same socket; this
            // middleware short-circuits H1 requests with 400 so the port
            // serves h2c exclusively from the app's perspective. The
            // validate.sh anti-cheat requires port 8082 to refuse HTTP/1.1.
            .wrap_fn(|req: ServiceRequest, srv| {
                if req.request().version() == Version::HTTP_11 {
                    let (r, _pl) = req.into_parts();
                    let resp = HttpResponse::BadRequest()
                        .content_type("text/plain")
                        .body("HTTP/2 cleartext prior-knowledge required");
                    Either::Left(ready(Ok(ServiceResponse::new(r, resp))))
                } else {
                    Either::Right(srv.call(req))
                }
            })
            .route("/baseline2", web::get().to(baseline2))
            .route("/json/{count}", web::get().to(json_endpoint))
    })
    .workers(workers)
    .bind_auto_h2c("0.0.0.0:8082")?
    .run()
    .await
}
