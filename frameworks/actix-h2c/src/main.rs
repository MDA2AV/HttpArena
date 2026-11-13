use actix_web::dev::{Service, ServiceRequest, ServiceResponse};
use actix_web::http::Version;
use actix_web::{web, App, HttpResponse, HttpServer};
use futures_util::future::{ready, Either};
use serde::{Deserialize, Serialize};
use std::io;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[derive(Deserialize)]
struct BaselineQuery {
    a: Option<i64>,
    b: Option<i64>,
}

#[derive(Deserialize)]
struct JsonQuery {
    m: Option<i64>,
}

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
struct RatingOut {
    score: i64,
    count: i64,
}

// Field order is the wire order: id..rating, then the computed total.
#[derive(Serialize)]
struct ProcessedItem<'a> {
    id: i64,
    name: &'a str,
    category: &'a str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'a [String],
    rating: RatingOut,
    total: i64,
}

#[derive(Serialize)]
struct JsonResponse<'a> {
    items: Vec<ProcessedItem<'a>>,
    count: usize,
}

// The first `count` items with their totals. Strings and tags are borrowed from
// the dataset: the response is still built and serialized on every request, it
// just does not copy every name, category and tag into it first.
fn build_json(dataset: &[DatasetItem], count: usize, m: i64) -> JsonResponse<'_> {
    let count = count.min(dataset.len());
    let items = dataset[..count]
        .iter()
        .map(|d| ProcessedItem {
            id: d.id,
            name: &d.name,
            category: &d.category,
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: &d.tags,
            rating: RatingOut {
                score: d.rating.score,
                count: d.rating.count,
            },
            total: d.price * d.quantity * m,
        })
        .collect();
    JsonResponse { items, count }
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
        .content_type("text/plain")
        .body(sum.to_string())
}

async fn json_endpoint(
    web::ThinData(dataset): web::ThinData<&'static [DatasetItem]>,
    path: web::Path<usize>,
    query: web::Query<JsonQuery>,
) -> HttpResponse {
    HttpResponse::Ok().json(&build_json(
        dataset,
        path.into_inner(),
        query.m.unwrap_or(1),
    ))
}

#[actix_web::main]
async fn main() -> io::Result<()> {
    // Leaked once at startup so handlers borrow the items instead of cloning
    // every string into each response.
    let dataset: &'static [DatasetItem] = Box::leak(load_dataset().into_boxed_slice());

    HttpServer::new(move || {
        App::new()
            .app_data(web::ThinData(dataset))
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
    .tcp_nodelay(true)
    .bind_auto_h2c("0.0.0.0:8082")?
    .run()
    .await
}
