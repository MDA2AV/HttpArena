// HttpArena entry: Pingora as a standalone HTTP/1.1 server.
//
// Pingora is a Rust library — not a ready-to-deploy server. We wrap it via
// the `ServeHttp` trait (from `pingora::apps::http_app`) to serve requests
// directly without an upstream, the same way we'd treat nginx or h2o as a
// server. No proxy modules are used.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use bytes::Bytes;
use http::{Response, StatusCode};

use pingora::apps::http_app::{HttpServer, ServeHttp};
use pingora::prelude::*;
use pingora::protocols::http::ServerSession;
use pingora::server::configuration::ServerConf;
use pingora::services::listening::Service;

// --- Static files ---------------------------------------------------------

struct StaticFile {
    data: Vec<u8>,
    content_type: &'static str,
}

fn mime_for(name: &str) -> &'static str {
    // Mirrors the nginx/h2o reference modules: only the extensions we actually
    // serve in the static test set. Unknown extensions fall back to octet-stream.
    if let Some(dot) = name.rfind('.') {
        match &name[dot..] {
            ".html" => "text/html",
            ".css" => "text/css",
            ".js" => "application/javascript",
            ".json" => "application/json",
            ".svg" => "image/svg+xml",
            ".webp" => "image/webp",
            ".woff2" => "font/woff2",
            _ => "application/octet-stream",
        }
    } else {
        "application/octet-stream"
    }
}

fn load_static_files() -> HashMap<String, StaticFile> {
    let mut files = HashMap::new();
    let Ok(entries) = std::fs::read_dir("/data/static") else {
        return files;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Ok(data) = std::fs::read(entry.path()) {
            let ct = mime_for(&name);
            files.insert(
                name,
                StaticFile {
                    data,
                    content_type: ct,
                },
            );
        }
    }
    files
}

// --- Query + body integer sum --------------------------------------------

// Parse one `&`-separated `k=v` pair list, summing the integer `v` values.
// Non-integer values are silently skipped — matches the nginx/h2o reference.
fn sum_query_values(query: &str) -> i64 {
    let mut sum: i64 = 0;
    for pair in query.split('&') {
        if pair.is_empty() {
            continue;
        }
        if let Some(eq) = pair.find('=') {
            let v = &pair[eq + 1..];
            // Stop at the first `&` fragment boundary is already handled by split.
            if let Ok(n) = v.parse::<i64>() {
                sum += n;
            }
        }
    }
    sum
}

fn parse_body_int(body: &[u8]) -> Option<i64> {
    let s = std::str::from_utf8(body).ok()?;
    s.trim().parse::<i64>().ok()
}

// --- App ------------------------------------------------------------------

struct HttpArenaApp {
    statics: Arc<HashMap<String, StaticFile>>,
}

impl HttpArenaApp {
    fn new(statics: Arc<HashMap<String, StaticFile>>) -> Self {
        Self { statics }
    }
}

// Read the full request body, capped at 64 KiB. The `read_request_body`
// method returns Some(chunk) until EOF, then None; any error aborts.
async fn read_full_body(session: &mut ServerSession) -> Bytes {
    const MAX: usize = 64 * 1024;
    let mut buf = bytes::BytesMut::new();
    loop {
        match session.read_request_body().await {
            Ok(Some(chunk)) => {
                if buf.len() + chunk.len() > MAX {
                    // Truncate — oversize bodies are not part of the baseline11 contract.
                    let remaining = MAX - buf.len();
                    buf.extend_from_slice(&chunk[..remaining]);
                    break;
                }
                buf.extend_from_slice(&chunk);
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }
    buf.freeze()
}

#[async_trait]
impl ServeHttp for HttpArenaApp {
    async fn response(&self, session: &mut ServerSession) -> Response<Vec<u8>> {
        let req = session.req_header();
        let method = req.method.clone();
        let uri = req.uri.clone();
        let path = uri.path();
        let query = uri.query().unwrap_or("");

        // /baseline11 — sum query args (+ body for POST), text/plain response.
        if path == "/baseline11" {
            let mut sum = sum_query_values(query);
            if method == http::Method::POST {
                let body = read_full_body(session).await;
                if let Some(n) = parse_body_int(&body) {
                    sum += n;
                }
            }
            let body = sum.to_string().into_bytes();
            return Response::builder()
                .status(StatusCode::OK)
                .header(http::header::CONTENT_TYPE, "text/plain")
                .header(http::header::CONTENT_LENGTH, body.len())
                .body(body)
                .unwrap();
        }

        // /pipeline — fixed "ok" response for the pipelined profile (16
        // requests per batch over HTTP/1.1 pipelining).
        if path == "/pipeline" {
            let body = b"ok".to_vec();
            return Response::builder()
                .status(StatusCode::OK)
                .header(http::header::CONTENT_TYPE, "text/plain")
                .header(http::header::CONTENT_LENGTH, body.len())
                .body(body)
                .unwrap();
        }

        // /static/<filename> — serve preloaded file from memory.
        if let Some(name) = path.strip_prefix("/static/") {
            if let Some(sf) = self.statics.get(name) {
                return Response::builder()
                    .status(StatusCode::OK)
                    .header(http::header::CONTENT_TYPE, sf.content_type)
                    .header(http::header::CONTENT_LENGTH, sf.data.len())
                    .body(sf.data.clone())
                    .unwrap();
            }
            return not_found();
        }

        not_found()
    }
}

fn not_found() -> Response<Vec<u8>> {
    let body = b"Not Found".to_vec();
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .header(http::header::CONTENT_TYPE, "text/plain")
        .header(http::header::CONTENT_LENGTH, body.len())
        .body(body)
        .unwrap()
}

// --- Main -----------------------------------------------------------------

fn main() {
    env_logger::init();

    // Threads per service. ServerConf::default().threads is 1, so explicitly
    // size to all available CPUs — Pingora uses this for each service's tokio
    // runtime (work-stealing within the service, not shared across services).
    let mut conf = ServerConf::default();
    conf.threads = num_cpus::get();

    // new_with_opt_and_conf avoids trying to parse CLI args or load a YAML
    // config file. bootstrap() must run before services are registered.
    let mut server = Server::new_with_opt_and_conf(None, conf);
    server.bootstrap();

    let statics = Arc::new(load_static_files());
    log::info!(
        "preloaded {} static files from /data/static",
        statics.len()
    );

    let app = HttpArenaApp::new(statics);
    let http_app = HttpServer::new_app(app);

    let mut http_service: Service<HttpServer<HttpArenaApp>> =
        Service::new("httparena-pingora".to_string(), http_app);
    http_service.add_tcp("0.0.0.0:8080");

    server.add_service(http_service);
    server.run_forever();
}
