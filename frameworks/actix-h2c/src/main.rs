use actix_web::dev::{Service, ServiceRequest, ServiceResponse};
use actix_web::http::header::{self, ContentType};
use actix_web::http::{Method, Version};
use actix_web::{web, App, HttpRequest, HttpResponse, HttpServer};
use futures_util::future::{ready, Either};
use futures_util::StreamExt;
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

// /spec, the compliance route (site/content/docs/test-profiles/compliance/):
// what h2spec needs from one route on this h2c listener, in the same shape as
// the actix entry's. GET answers a fixed body of at least five bytes - h2spec
// skips a flow-control test below that - and POST echoes the body.
async fn spec_text() -> HttpResponse {
    HttpResponse::Ok().content_type(ContentType::plaintext()).body("spec ok")
}

async fn spec_echo(mut payload: web::Payload) -> HttpResponse {
    let mut body = web::BytesMut::new();
    while let Some(chunk) = payload.next().await {
        match chunk {
            Ok(data) => body.extend_from_slice(&data),
            Err(_) => return HttpResponse::BadRequest().finish(),
        }
    }
    HttpResponse::Ok()
        .content_type(ContentType::octet_stream())
        .body(body.freeze())
}

async fn spec_options(mut payload: web::Payload) -> HttpResponse {
    while payload.next().await.is_some() {}
    HttpResponse::Ok()
        .insert_header((header::ALLOW, "GET, HEAD, POST, OPTIONS"))
        .finish()
}

async fn spec_headers(req: HttpRequest, mut payload: web::Payload) -> HttpResponse {
    while payload.next().await.is_some() {}
    let mut out = String::new();
    for (name, value) in req.headers().iter() {
        out.push_str(name.as_str());
        out.push_str(": ");
        out.push_str(&String::from_utf8_lossy(value.as_bytes()));
        out.push('\n');
    }
    HttpResponse::Ok().content_type(ContentType::plaintext()).body(out)
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
            .service(
                web::resource("/spec")
                    .route(web::get().to(spec_text))
                    .route(web::head().to(spec_text))
                    .route(web::method(Method::OPTIONS).to(spec_options))
                    .route(web::post().to(spec_echo)),
            )
            .service(
                web::resource("/spec/headers")
                    .route(web::get().to(spec_headers))
                    .route(web::post().to(spec_headers)),
            )
    })
    .tcp_nodelay(true)
    .bind_auto_h2c("0.0.0.0:8082")?
    .run()
    .await
}
