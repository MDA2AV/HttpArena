use std::{io, path::Path};

use ntex::http::{self, HttpService};
use ntex::server::LoadBalancing;
use ntex::web::{self, App, HttpResponse};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use serde::{Deserialize, Serialize};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

type QueryParams = web::types::Query<Vec<(String, String)>>;

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
struct OutRating {
    score: i64,
    count: i64,
}

// Field order is the wire order: id..rating then the computed total.
#[derive(Serialize)]
struct OutItem<'a> {
    id: i64,
    name: &'a str,
    category: &'a str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'a [String],
    rating: OutRating,
    total: i64,
}

#[derive(Serialize)]
struct OutList<'a> {
    items: Vec<OutItem<'a>>,
    count: usize,
}

fn load_dataset() -> Vec<DatasetItem> {
    let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

/// Sum of every query parameter whose value parses as an integer; a
/// non-numeric one is skipped rather than failing the request.
fn sum_query(query: &[(String, String)]) -> i64 {
    query
        .iter()
        .filter_map(|(_, value)| value.trim().parse::<i64>().ok())
        .sum()
}

async fn baseline2(query: QueryParams) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(sum_query(&query).to_string())
}

fn build_json(dataset: &[DatasetItem], count: usize, m: i64) -> OutList<'_> {
    let n = count.min(dataset.len());
    let items = dataset[..n]
        .iter()
        .map(|d| OutItem {
            id: d.id,
            name: &d.name,
            category: &d.category,
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: &d.tags,
            rating: OutRating {
                score: d.rating.score,
                count: d.rating.count,
            },
            total: d.price * d.quantity * m,
        })
        .collect();
    OutList { items, count: n }
}

async fn json_items(
    query: QueryParams,
    path: web::types::Path<usize>,
    dataset: &[DatasetItem],
) -> HttpResponse {
    let m = query
        .iter()
        .find_map(|(key, value)| (key == "m").then_some(value))
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(1);
    HttpResponse::Ok().json(&build_json(dataset, path.into_inner(), m))
}

fn load_tls_config(cert: &Path, key: &Path) -> io::Result<rustls::ServerConfig> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let certs = CertificateDer::pem_file_iter(cert)
        .and_then(|certs| certs.collect::<Result<Vec<_>, _>>())
        .map_err(io::Error::other)?;
    let key = PrivateKeyDer::from_pem_file(key).map_err(io::Error::other)?;
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(io::Error::other)?;
    // The listener is HTTP/2-only, so `h2` is the only protocol offered.
    tls.alpn_protocols = vec![b"h2".to_vec()];
    Ok(tls)
}

#[ntex::main]
async fn main() -> io::Result<()> {
    // Leaked once at startup so handlers borrow the items instead of cloning
    // every string into each response.
    let dataset: &'static [DatasetItem] = Box::leak(load_dataset().into_boxed_slice());
    let static_dir: &'static Path = Path::new("/data/static");
    let app = move || {
        App::new()
            .route("/baseline2", web::get().to(baseline2))
            .route(
                "/json/{count}",
                web::get().to(async move |query, path| json_items(query, path, dataset).await),
            )
            .service(
                ntex_files::Files::new("/static", static_dir)
                    .try_compressed()
                    .disable_content_disposition(),
            )
    };

    // HTTP/2-only service: every connection must open with the h2 preface
    // (prior knowledge), there is no HTTP/1.1 fallback on this port.
    // Each worker accepts connections on its own `SO_REUSEPORT` listener.
    let mut srv = ntex::server::build()
        .backlog(1024)
        .load_balancing(LoadBalancing::Reuseport)
        .bind(
            "h2c",
            "0.0.0.0:8082",
            ntex::SharedCfg::default(),
            async move |_| HttpService::h2(app()),
        )?;

    // The harness mounts /certs only for the TLS profile, so a missing pair
    // leaves the TLS listener down instead of aborting startup.
    let cert = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".into());
    let key = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".into());
    let (cert, key) = (Path::new(&cert), Path::new(&key));
    if cert.exists() && key.exists() {
        let tls = load_tls_config(cert, key)?;
        srv = srv.bind(
            "h2-tls",
            "0.0.0.0:8443",
            ntex::SharedCfg::default(),
            async move |_| http::rustls(tls.clone(), &[], HttpService::h2(app())),
        )?;
    }

    srv.run().await
}
