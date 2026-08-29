use once_cell::sync::OnceCell;
use salvo::compression::{Compression, CompressionLevel};
use salvo::conn::rustls::{Keycert, RustlsConfig};
use salvo::prelude::*;
use serde::{Deserialize, Serialize};

const MAX_BODY: usize = 64 * 1024 * 1024;

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

static DATASET: OnceCell<Vec<DatasetItem>> = OnceCell::new();

fn dataset() -> &'static [DatasetItem] {
    DATASET.get().map(|v| v.as_slice()).unwrap_or(&[])
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
fn sum_query(query: &str) -> i64 {
    let mut total = 0i64;
    for pair in query.split('&') {
        if let Some((_, value)) = pair.split_once('=') {
            if let Ok(n) = value.trim().parse::<i64>() {
                total += n;
            }
        }
    }
    total
}

#[handler]
async fn baseline11(req: &mut Request, res: &mut Response) {
    let mut total = sum_query(req.uri().query().unwrap_or(""));
    if let Ok(body) = req.payload_with_max_size(MAX_BODY).await {
        if let Ok(text) = std::str::from_utf8(body) {
            if let Ok(n) = text.trim().parse::<i64>() {
                total += n;
            }
        }
    }
    res.headers_mut()
        .insert("content-type", "text/plain".parse().unwrap());
    res.write_body(total.to_string()).ok();
}

#[handler]
async fn json_items(req: &mut Request, res: &mut Response) {
    let count: usize = req.param::<usize>("count").unwrap_or(0);
    let m: i64 = req.query::<i64>("m").unwrap_or(1);

    let all = dataset();
    let n = count.min(all.len());
    let items = all[..n]
        .iter()
        .map(|d| OutItem {
            id: d.id,
            name: &d.name,
            category: &d.category,
            price: d.price,
            quantity: d.quantity,
            active: d.active,
            tags: &d.tags,
            rating: OutRating { score: d.rating.score, count: d.rating.count },
            total: d.price * d.quantity * m,
        })
        .collect();

    // Salvo's own JSON response. The Compression hoop in the router handles
    // json-comp, so nothing is encoded here.
    res.render(Json(OutList { items, count: n }));
}

#[handler]
// Echo: the payload salvo collected goes back unchanged. It is read whole
// first, which is also what makes a chunked request work -- there is no
// Content-Length to frame the response from until the body is in.
async fn echo_body(req: &mut Request, res: &mut Response) {
    // clone() on Bytes is a refcount bump, not a 100 KB copy.
    let Ok(body) = req.payload_with_max_size(MAX_BODY).await.map(|b| b.clone()) else {
        res.status_code(StatusCode::BAD_REQUEST);
        return;
    };
    res.headers_mut()
        .insert("content-type", "application/octet-stream".parse().unwrap());
    res.write_body(body).ok();
}

fn router() -> Router {
    // Compression only wraps /json: it is what json-comp negotiates on, and
    // leaving it off the other routes keeps them on the plain write path.
    // Fastest is salvo's level 1, which is what the profile asks for -- Minsize
    // would score better on the bandwidth term and is not the rule.
    Router::new()
        .push(
            Router::with_path("baseline11")
                .get(baseline11)
                .post(baseline11),
        )
        .push(
            Router::with_path("json/{count}")
                .hoop(
                    Compression::new()
                        .enable_gzip(CompressionLevel::Fastest)
                        .enable_brotli(CompressionLevel::Fastest),
                )
                .get(json_items),
        )
        .push(Router::with_path("echo").post(echo_body))
}

#[tokio::main]
async fn main() {
    DATASET.set(load_dataset()).ok();

    // json-tls on 8081. The harness mounts /certs only for the TLS profiles,
    // so a missing pair leaves the listener down rather than aborting startup.
    let cert = std::path::Path::new("/certs/server.crt");
    let key = std::path::Path::new("/certs/server.key");
    if cert.exists() && key.exists() {
        let tls = RustlsConfig::new(
            Keycert::new()
                .cert(std::fs::read(cert).unwrap())
                .key(std::fs::read(key).unwrap()),
        );
        tokio::spawn(async move {
            let acceptor = TcpListener::new("0.0.0.0:8081").rustls(tls).bind().await;
            Server::new(acceptor).serve(router()).await;
        });
    }

    let acceptor = TcpListener::new("0.0.0.0:8080").bind().await;
    Server::new(acceptor).serve(router()).await;
}
