use std::path::Path;

use ntex::http::header::{self, ContentEncoding};
use ntex::http::{self, HttpService};
use ntex::io::IoConfig;
use ntex::util::{BytePageSize, Bytes};
use ntex::web::{self, App, HttpRequest, HttpResponse, middleware};
use ntex_files::NamedFile;
use serde::{Deserialize, Serialize};

mod db;
mod fortunes;

const MAX_BODY: usize = 64 * 1024 * 1024;
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

async fn delay(path: web::types::Path<u64>) -> HttpResponse {
    let ms = path.into_inner();
    if ms > 0 {
        ntex::time::sleep(std::time::Duration::from_millis(ms)).await;
    }
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(ms.to_string())
}

async fn baseline11(query: QueryParams, body: Bytes) -> HttpResponse {
    let mut total = sum_query(&query);
    if let Ok(text) = std::str::from_utf8(&body)
        && let Ok(n) = text.trim().parse::<i64>()
    {
        total += n;
    }
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(total.to_string())
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
    HttpResponse::Ok()
        .header("Vary", "Accept-Encoding")
        .json(&build_json(dataset, path.into_inner(), m))
}

// Echo: ntex has already collected the body (chunked or not) into Bytes, so
// the response is that buffer unchanged.
async fn echo_body(body: Bytes) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("application/octet-stream")
        .body(body)
}

async fn pipeline() -> HttpResponse {
    HttpResponse::Ok().content_type("text/plain").body("ok")
}

async fn baseline2(query: QueryParams) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(sum_query(&query).to_string())
}

/// Encodings acceptable to the client in preference order, best first.
///
/// Only the precompressed `br` and `gzip` siblings exist on disk; a coding
/// with `q=0` is refused, and `br` wins ties.
fn accepted_encodings(accept: &str) -> Vec<ContentEncoding> {
    let (mut br, mut gzip, mut any) = (None, None, None);
    for entry in accept.split(',') {
        let mut parts = entry.split(';');
        let coding = parts.next().unwrap_or("").trim();
        let q = parts
            .find_map(|p| p.trim().strip_prefix("q=").or(p.trim().strip_prefix("Q=")))
            .map_or(Some(1.0), |q| q.trim().parse::<f32>().ok())
            .unwrap_or(0.0);
        if coding.eq_ignore_ascii_case("br") {
            br = Some(q);
        } else if coding.eq_ignore_ascii_case("gzip") || coding.eq_ignore_ascii_case("x-gzip") {
            gzip = Some(q);
        } else if coding == "*" {
            any = Some(q);
        }
    }
    let br = br.or(any).unwrap_or(0.0);
    let gzip = gzip.or(any).unwrap_or(0.0);
    let mut out = Vec::with_capacity(2);
    for (q, encoding) in [(br, ContentEncoding::Br), (gzip, ContentEncoding::Gzip)] {
        if q > 0.0 {
            out.push((q, encoding));
        }
    }
    out.sort_by(|a, b| b.0.total_cmp(&a.0));
    out.into_iter().map(|(_, encoding)| encoding).collect()
}

/// Opens `path` as a regular file, typed and named after `original`.
fn open_file(path: &Path, original: &Path) -> Option<NamedFile> {
    let file = std::fs::File::open(path).ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    NamedFile::from_file(file, original).ok()
}

/// Serves `/static/{name}` straight from disk on every request. A `.br` or
/// `.gz` sibling is sent when the client accepts it, with the original file's
/// Content-Type and the matching Content-Encoding.
async fn static_file(req: HttpRequest, dir: &Path) -> HttpResponse {
    let name = req.match_info().get("name").unwrap_or_default();
    if name.is_empty() || name.starts_with('.') || name.contains(['/', '\\']) {
        return HttpResponse::NotFound().build();
    }
    let path = dir.join(name);
    let accept = req
        .headers()
        .get(header::ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let mut selected = None;
    for encoding in accepted_encodings(accept) {
        let suffix = if encoding == ContentEncoding::Br {
            "br"
        } else {
            "gz"
        };
        let mut variant = path.clone().into_os_string();
        variant.push(".");
        variant.push(suffix);
        if let Some(file) = open_file(Path::new(&variant), &path) {
            selected = Some((file, encoding));
            break;
        }
    }
    let (file, encoding) = match selected {
        Some(selected) => selected,
        None => match open_file(&path, &path) {
            Some(file) => (file, ContentEncoding::Identity),
            None => return HttpResponse::NotFound().build(),
        },
    };

    let mut response = file.disable_content_disposition().into_response(&req);
    let headers = response.headers_mut();
    if encoding != ContentEncoding::Identity {
        headers.insert(
            header::CONTENT_ENCODING,
            header::HeaderValue::from_static(encoding.as_str()),
        );
    }
    headers.insert(
        header::VARY,
        header::HeaderValue::from_static("accept-encoding"),
    );
    response
}

fn routes(
    cfg: &mut web::ServiceConfig<()>,
    dataset: &'static [DatasetItem],
    static_dir: &'static Path,
) {
    cfg.service(
        web::resource("/baseline11")
            .route(web::get().to(baseline11))
            .route(web::post().to(baseline11)),
    )
    .service(web::resource("/baseline2").route(web::get().to(baseline2)))
    .service(web::resource("/pipeline").route(web::get().to(pipeline)))
    .service(web::resource("/async-db").route(web::get().to(db::async_db)))
    .service(web::resource("/fortunes").route(web::get().to(fortunes::fortunes)))
    .service(
        web::resource("/static/{name}")
            .route(web::get().to(async move |req| static_file(req, static_dir).await)),
    )
    .service(web::resource("/delay/{ms}").route(web::get().to(delay)))
    .service(
        web::resource("/json/{count}")
            .middleware(middleware::Compress::default())
            .route(web::get().to(async move |query, path| json_items(query, path, dataset).await)),
    )
    .service(web::resource("/echo").route(web::post().to(echo_body)));
}

fn app_config() -> web::WebAppConfig {
    web::WebAppConfig::new().set_state(web::types::PayloadConfig::new(MAX_BODY))
}

fn server_config(write_page: BytePageSize) -> ntex::SharedCfg {
    ntex::SharedCfg::new("HTTPARENA")
        .add(
            IoConfig::new()
                .set_read_size(BytePageSize::Size8, BytePageSize::Size64)
                .set_write_size(write_page)
                .set_write_backpressure(256 * 1024),
        )
        .into()
}

fn load_tls_config(
    cert: impl std::io::Read,
    key: impl std::io::Read,
    alpn: &[&[u8]],
) -> std::io::Result<rustls::ServerConfig> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let certs =
        rustls_pemfile::certs(&mut std::io::BufReader::new(cert)).collect::<Result<_, _>>()?;
    let private = rustls_pemfile::private_key(&mut std::io::BufReader::new(key))?
        .expect("no private key in server.key");
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, private)
        .expect("bad certificate/key pair");
    tls.alpn_protocols = alpn.iter().map(|p| p.to_vec()).collect();
    Ok(tls)
}

const ALPN_H1: &[&[u8]] = &[b"http/1.1"];
const ALPN_H2: &[&[u8]] = &[b"h2", b"http/1.1"];

/// Threads accepting connections, each with its own `SO_REUSEPORT` listener.
const ACCEPTORS: usize = 8;

#[ntex::main(timer_resolution = 2)]
async fn main() -> std::io::Result<()> {
    // Leaked once at startup so handlers borrow the items instead of cloning
    // every string into each response.
    let dataset: &'static [DatasetItem] = Box::leak(load_dataset().into_boxed_slice());
    let static_dir: &'static Path = Path::new("/data/static");

    // ntex starts one worker per CPU the process may use and pins each worker
    // to one CPU, so the count is taken here, before any worker starts.
    db::set_workers(std::thread::available_parallelism().map_or(1, |n| n.get()));

    let app = async move |_: &()| {
        db::init();
        App::new()
            .with_config(app_config())
            .configure(|cfg| routes(cfg, dataset, static_dir))
    };

    // `web::HttpServer` does not expose the number of accept threads, so the
    // server is assembled from the http service directly.
    let mut server = ntex::server::build()
        .backlog(1024)
        .acceptors(ACCEPTORS)
        .bind(
            "http",
            "0.0.0.0:8080",
            server_config(BytePageSize::Size4),
            async move |st| HttpService::new(app(st).await),
        )?;

    // The harness mounts /certs only for the TLS profiles, so a missing pair
    // leaves the TLS listeners down rather than aborting startup.
    let cert = Path::new("/certs/server.crt");
    let key = Path::new("/certs/server.key");
    if cert.exists() && key.exists() {
        // json-tls and static-tls on 8081 are exclusively HTTP/1.1.
        let tls = load_tls_config(
            std::fs::File::open(cert)?,
            std::fs::File::open(key)?,
            ALPN_H1,
        )?;
        server = server.bind(
            "tls-h1",
            "0.0.0.0:8081",
            server_config(BytePageSize::Size16),
            async move |st| http::rustls(tls.clone(), &[], HttpService::new(app(st).await)),
        )?;
        // baseline-h2 and static-h2 negotiate h2 on 8443.
        let tls = load_tls_config(
            std::fs::File::open(cert)?,
            std::fs::File::open(key)?,
            ALPN_H2,
        )?;
        server = server.bind(
            "tls-h2",
            "0.0.0.0:8443",
            server_config(BytePageSize::Size16),
            async move |st| http::rustls(tls.clone(), &[], HttpService::new(app(st).await)),
        )?;
    }

    server.run().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use ntex::http::StatusCode;
    use ntex::web::test::{self, TestRequest};
    use std::io::Read;

    fn static_dir() -> &'static Path {
        Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../../data/static"))
    }

    #[ntex::test]
    async fn baseline_query_and_body() {
        let app =
            test::init_service(App::new().configure(|cfg| routes(cfg, &[], static_dir()))).await;

        for (uri, body, expected) in [
            ("/baseline11?a=13&b=42", "20", "75"),
            ("/baseline11?a=%31%33&b=%2B42&a=-1&ignored=no", " 20 ", "74"),
            ("/baseline11", "", "0"),
        ] {
            let response = app
                .call(TestRequest::post().uri(uri).payload(body).to_request())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(test::read_body(response).await, expected);
        }
    }

    #[ntex::test]
    async fn json_serialization_and_compression() {
        let dataset: &'static [DatasetItem] = Box::leak(
            (1..=50)
                .map(|id| DatasetItem {
                    id,
                    name: format!("Item {id}"),
                    category: "test".into(),
                    price: id * 3,
                    quantity: 2,
                    active: true,
                    tags: vec!["tag".into()],
                    rating: Rating { score: 4, count: 7 },
                })
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        );
        let server = test::server_with(
            test::config().server_cfg(server_config(BytePageSize::Size4)),
            async move |_| {
                App::new()
                    .with_config(app_config())
                    .configure(|cfg| routes(cfg, dataset, static_dir()))
            },
        );

        for (count, multiplier, accept, compressed) in [
            (25, 4, "gzip, br", true),
            (40, 8, "identity", false),
            (50, 6, "gzip;q=0", false),
            (60, 1, "gzip", true),
        ] {
            let response = server
                .get(format!("/json/{count}?m={multiplier}"))
                .header("Accept-Encoding", accept)
                .no_decompress()
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(
                response
                    .headers()
                    .get("Content-Encoding")
                    .map(|v| v.as_bytes()),
                compressed.then_some(b"gzip".as_slice())
            );
            let bytes = response.body().await.unwrap();
            let bytes = if compressed {
                let mut decoded = Vec::new();
                flate2::read::GzDecoder::new(bytes.as_ref())
                    .read_to_end(&mut decoded)
                    .unwrap();
                decoded
            } else {
                bytes.to_vec()
            };
            let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(body["count"], count.min(50));
            let items = body["items"].as_array().unwrap();
            assert_eq!(items.len(), count.min(50) as usize);
            for (index, item) in items.iter().enumerate() {
                let id = index + 1;
                assert_eq!(
                    item,
                    &serde_json::json!({
                        "id": id, "name": format!("Item {id}"), "category": "test",
                        "price": id * 3, "quantity": 2, "active": true,
                        "tags": ["tag"], "rating": {"score": 4, "count": 7},
                        "total": id * 6 * multiplier
                    })
                );
            }
        }
        server.stop().await;
    }

    #[ntex::test]
    async fn native_tls_echo_and_delay() {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let tls = load_tls_config(
            cert.pem().as_bytes(),
            signing_key.serialize_pem().as_bytes(),
            ALPN_H1,
        )
        .unwrap();
        let mut roots = rustls::RootCertStore::empty();
        roots.add(cert.der().clone()).unwrap();
        let mut client_tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        client_tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
        let client = ntex::client::Client::builder()
            .rustls(client_tls)
            .build(ntex::SharedCfg::default());
        let server = test::server_with(
            test::config()
                .rustls(tls)
                .server_cfg(server_config(BytePageSize::Size16)),
            async |_| {
                App::new()
                    .with_config(app_config())
                    .configure(|cfg| routes(cfg, &[], static_dir()))
            },
        );

        for size in [10 * 1024, 20 * 1024 * 1024] {
            let payload = Bytes::from(vec![b'x'; size]);
            let response = client
                .post(server.url("/echo"))
                .header("Accept-Encoding", "gzip")
                .send_body(payload.clone())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.version(), ntex::http::Version::HTTP_11);
            assert!(!response.headers().contains_key("Content-Encoding"));
            assert_eq!(response.body().limit(MAX_BODY).await.unwrap(), payload);
        }

        let start = std::time::Instant::now();
        let response = client.get(server.url("/delay/40")).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.body().await.unwrap(), "40");
        assert!(start.elapsed() >= std::time::Duration::from_millis(40));
        server.stop().await;
    }

    /// STATEMENT: `/pipeline` and `/baseline2` answer with plain-text bodies.
    ///
    /// HOW:
    /// - Call `/pipeline` and `/baseline2?a=13&b=42&a=x` on the test service.
    /// - Confirm both are `200 OK` `text/plain` with bodies `ok` and `55`,
    ///   ignoring the non-numeric parameter.
    #[ntex::test]
    async fn pipeline_and_baseline2() {
        let app =
            test::init_service(App::new().configure(|cfg| routes(cfg, &[], static_dir()))).await;

        for (uri, expected) in [("/pipeline", "ok"), ("/baseline2?a=13&b=42&a=x", "55")] {
            let response = app
                .call(TestRequest::get().uri(uri).to_request())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(
                response.headers().get(header::CONTENT_TYPE).unwrap(),
                "text/plain"
            );
            assert_eq!(test::read_body(response).await, expected);
        }
    }

    /// STATEMENT: `accepted_encodings` orders `br` and `gzip` by q-value and
    /// drops refused codings.
    ///
    /// HOW:
    /// - Parse headers covering ties, explicit q-values, `x-gzip`, `*`,
    ///   `q=0`, malformed q-values and unsupported codings.
    /// - Compare each result with the expected preference list.
    #[test]
    fn accept_encoding_preference() {
        use ContentEncoding::{Br, Gzip};
        for (accept, expected) in [
            ("", vec![]),
            ("identity, deflate", vec![]),
            ("gzip, br", vec![Br, Gzip]),
            ("gzip;q=1.0, br;q=0.5", vec![Gzip, Br]),
            ("BR; Q=0.2, x-gzip;q=0.3", vec![Gzip, Br]),
            ("br;q=0, gzip", vec![Gzip]),
            ("*;q=0.5, gzip;q=0", vec![Br]),
            ("*", vec![Br, Gzip]),
            ("br;q=bogus, gzip", vec![Gzip]),
        ] {
            assert_eq!(accepted_encodings(accept), expected, "{accept}");
        }
    }

    /// STATEMENT: `/static/{name}` serves the best precompressed sibling with
    /// the original Content-Type, and falls back to the identity file.
    ///
    /// HOW:
    /// - Request `app.js`, `reset.css` and `hero.webp` with `br`, `gzip`
    ///   and no `Accept-Encoding`.
    /// - Confirm Content-Type follows the original name, Content-Encoding
    ///   names the sibling sent, `Vary` is set, and the body equals the
    ///   matching file on disk (`hero.webp` has no siblings, so it is always
    ///   sent unencoded).
    #[ntex::test]
    async fn static_files_select_precompressed_siblings() {
        let app =
            test::init_service(App::new().configure(|cfg| routes(cfg, &[], static_dir()))).await;

        for (name, accept, encoding, suffix, content_type) in [
            ("app.js", "gzip, br", Some("br"), ".br", "javascript"),
            (
                "app.js",
                "br;q=0.1, gzip",
                Some("gzip"),
                ".gz",
                "javascript",
            ),
            ("reset.css", "", None, "", "text/css"),
            ("reset.css", "br;q=0, gzip;q=0", None, "", "text/css"),
            ("hero.webp", "br, gzip", None, "", "image/webp"),
        ] {
            let response = app
                .call(
                    TestRequest::get()
                        .uri(&format!("/static/{name}"))
                        .header(header::ACCEPT_ENCODING, accept)
                        .to_request(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{name} {accept}");
            let headers = response.headers();
            let ctype = headers.get(header::CONTENT_TYPE).unwrap().to_str().unwrap();
            assert!(ctype.contains(content_type), "{name}: {ctype}");
            assert_eq!(
                headers
                    .get(header::CONTENT_ENCODING)
                    .map(|v| v.to_str().unwrap()),
                encoding,
                "{name} {accept}"
            );
            assert_eq!(headers.get(header::VARY).unwrap(), "accept-encoding");
            assert!(!headers.contains_key(header::CONTENT_DISPOSITION));
            let expected = std::fs::read(static_dir().join(format!("{name}{suffix}"))).unwrap();
            assert_eq!(test::read_body(response).await, expected);
        }
    }

    /// STATEMENT: `/static/{name}` rejects missing files, directories and
    /// names that could escape the static directory.
    ///
    /// HOW:
    /// - Request a missing file, a dot file, encoded traversal and encoded
    ///   separators.
    /// - Confirm every request is `404 Not Found`.
    #[ntex::test]
    async fn static_files_reject_missing_and_traversal() {
        let app =
            test::init_service(App::new().configure(|cfg| routes(cfg, &[], static_dir()))).await;

        for uri in [
            "/static/nonexistent.txt",
            "/static/..",
            "/static/.hidden",
            "/static/..%2Fdataset.json",
            "/static/..%2F..%2Fframeworks%2Fntex%2FCargo.toml",
            "/static/..%5C..%5Cframeworks%5Cntex%5CCargo.toml",
        ] {
            let response = app
                .call(TestRequest::get().uri(uri).to_request())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND, "{uri}");
        }
    }

    /// STATEMENT: The 8443 TLS configuration negotiates HTTP/2 and serves the
    /// h2 profiles.
    ///
    /// HOW:
    /// - Start a rustls test server with `ALPN_H2` and a client offering `h2`.
    /// - Confirm `/baseline2` returns `55` and `/static/app.js` returns the
    ///   brotli sibling, both over `Version::HTTP_2`.
    #[ntex::test]
    async fn h2_tls_baseline_and_static() {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let tls = load_tls_config(
            cert.pem().as_bytes(),
            signing_key.serialize_pem().as_bytes(),
            ALPN_H2,
        )
        .unwrap();
        let mut roots = rustls::RootCertStore::empty();
        roots.add(cert.der().clone()).unwrap();
        let mut client_tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        client_tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
        let client = ntex::client::Client::builder()
            .rustls(client_tls)
            .build(ntex::SharedCfg::default());
        let server = test::server_with(
            test::config()
                .rustls(tls)
                .server_cfg(server_config(BytePageSize::Size16)),
            async |_| {
                App::new()
                    .with_config(app_config())
                    .configure(|cfg| routes(cfg, &[], static_dir()))
            },
        );

        let response = client
            .get(server.url("/baseline2?a=13&b=42"))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.version(), ntex::http::Version::HTTP_2);
        assert_eq!(response.body().await.unwrap(), "55");

        let response = client
            .get(server.url("/static/app.js"))
            .header("Accept-Encoding", "br")
            .no_decompress()
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.version(), ntex::http::Version::HTTP_2);
        assert_eq!(response.headers().get("Content-Encoding").unwrap(), "br");
        let expected = std::fs::read(static_dir().join("app.js.br")).unwrap();
        assert_eq!(response.body().limit(MAX_BODY).await.unwrap(), expected);
        server.stop().await;
    }
}
