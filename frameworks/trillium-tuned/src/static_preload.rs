//! In-memory static file serving with precompressed (.br / .gz) sidecar support.
//!
//! Allowed under `tuned` per arena's static-profile rules: load files into memory at startup
//! and serve precompressed variants from disk when `Accept-Encoding` requests them.

use std::{collections::HashMap, sync::Arc};
use trillium::{Conn, Handler, KnownHeaderName, Status};

#[derive(Debug)]
struct StaticFile {
    content_type: &'static str,
    plain: Vec<u8>,
    br: Option<Vec<u8>>,
    gz: Option<Vec<u8>>,
}

#[derive(Clone)]
pub struct StaticPreload {
    files: Arc<HashMap<String, StaticFile>>,
}

fn content_type_for(name: &str) -> &'static str {
    match name.rsplit('.').next().unwrap_or("") {
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "html" | "htm" => "text/html; charset=utf-8",
        "json" => "application/json",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "ico" => "image/x-icon",
        "txt" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

impl StaticPreload {
    pub fn load(dir: &str) -> Self {
        let mut files: HashMap<String, StaticFile> = HashMap::new();

        let Ok(entries) = std::fs::read_dir(dir) else {
            log::warn!("static dir {dir} not readable; preload empty");
            return Self {
                files: Arc::new(files),
            };
        };

        for entry in entries.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if !file_type.is_file() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            let Ok(bytes) = std::fs::read(entry.path()) else {
                continue;
            };

            if let Some(base) = name.strip_suffix(".br") {
                files
                    .entry(base.to_string())
                    .or_insert_with(|| StaticFile {
                        content_type: content_type_for(base),
                        plain: Vec::new(),
                        br: None,
                        gz: None,
                    })
                    .br = Some(bytes);
            } else if let Some(base) = name.strip_suffix(".gz") {
                files
                    .entry(base.to_string())
                    .or_insert_with(|| StaticFile {
                        content_type: content_type_for(base),
                        plain: Vec::new(),
                        br: None,
                        gz: None,
                    })
                    .gz = Some(bytes);
            } else {
                let entry = files.entry(name.clone()).or_insert_with(|| StaticFile {
                    content_type: content_type_for(&name),
                    plain: Vec::new(),
                    br: None,
                    gz: None,
                });
                entry.plain = bytes;
            }
        }

        log::info!("static preload: {} files from {}", files.len(), dir);
        Self {
            files: Arc::new(files),
        }
    }
}

impl Handler for StaticPreload {
    async fn run(&self, conn: Conn) -> Conn {
        let name = conn.path().trim_start_matches('/');
        let Some(file) = self.files.get(name) else {
            return conn.with_status(Status::NotFound).halt();
        };

        let accept = conn
            .request_headers()
            .get_str(KnownHeaderName::AcceptEncoding)
            .unwrap_or("");

        let (body, encoding): (&Vec<u8>, Option<&str>) =
            if let (Some(br), true) = (file.br.as_ref(), accept.contains("br")) {
                (br, Some("br"))
            } else if let (Some(gz), true) = (file.gz.as_ref(), accept.contains("gzip")) {
                (gz, Some("gzip"))
            } else {
                (&file.plain, None)
            };

        let mut conn = conn
            .with_status(Status::Ok)
            .with_response_header(KnownHeaderName::ContentType, file.content_type)
            .with_body(body.clone());

        if let Some(enc) = encoding {
            conn = conn.with_response_header(KnownHeaderName::ContentEncoding, enc);
        }
        conn.halt()
    }
}
