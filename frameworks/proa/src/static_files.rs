use std::{env, fs, sync::LazyLock};

use axum::{
    body::Bytes,
    extract::Path,
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{ACCEPT_ENCODING, CONTENT_ENCODING, CONTENT_TYPE, VARY},
    },
    response::{IntoResponse, Response},
};

const TEXT_CSS: HeaderValue = HeaderValue::from_static("text/css");
const APP_JS: HeaderValue = HeaderValue::from_static("application/javascript");
const TEXT_HTML: HeaderValue = HeaderValue::from_static("text/html; charset=utf-8");
const APP_JSON: HeaderValue = HeaderValue::from_static("application/json");
const IMAGE_SVG: HeaderValue = HeaderValue::from_static("image/svg+xml");
const FONT_WOFF2: HeaderValue = HeaderValue::from_static("font/woff2");
const IMAGE_WEBP: HeaderValue = HeaderValue::from_static("image/webp");
const APP_OCTET: HeaderValue = HeaderValue::from_static("application/octet-stream");
const ENC_BR: HeaderValue = HeaderValue::from_static("br");
const ENC_GZIP: HeaderValue = HeaderValue::from_static("gzip");
const VARY_AE: HeaderValue = HeaderValue::from_static("Accept-Encoding");

static STATIC_DIR: LazyLock<String> = LazyLock::new(|| {
    env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".to_string())
});

pub struct StaticFile {
    pub content_type: HeaderValue,
    pub content_encoding: Option<HeaderValue>,
    pub body: Bytes,
}

#[inline]
fn content_type_and_compressible(path: &str) -> (HeaderValue, bool) {
    let ext = path.rsplit_once('.').map_or("", |(_, e)| e);
    match ext {
        "css" => (TEXT_CSS, true),
        "js" => (APP_JS, true),
        "html" => (TEXT_HTML, true),
        "json" => (APP_JSON, true),
        "svg" => (IMAGE_SVG, true),
        "woff2" => (FONT_WOFF2, false),
        "webp" => (IMAGE_WEBP, false),
        _ => (APP_OCTET, false),
    }
}

#[inline]
fn parse_accept_encoding(header: Option<&str>) -> (bool, bool) {
    let Some(raw) = header else {
        return (false, false);
    };
    let mut br = false;
    let mut gzip = false;
    for part in raw.split(',') {
        let mut iter = part.split(';');
        let token = iter.next().unwrap_or("").trim();
        let rejected = iter.any(|param| {
            let p = param.trim();
            p == "q=0" || p == "q=0.0" || p == "q=0.00" || p == "q=0.000"
        });
        if rejected {
            continue;
        }
        if token.eq_ignore_ascii_case("br") {
            br = true;
        } else if token.eq_ignore_ascii_case("gzip") {
            gzip = true;
        }
    }
    (br, gzip)
}

#[inline]
fn is_safe_rel_path(rel: &str) -> bool {
    !rel.is_empty()
        && !rel.starts_with('/')
        && !rel.contains("..")
        && !rel.contains('\\')
        && !rel.as_bytes().contains(&0)
}

/// Reads the requested file (or its pre-compressed `.br`/`.gz` sibling) directly
/// from disk on every request so modifications on disk are reflected immediately.
pub fn read_static(rel_path: &str, accept_encoding: Option<&str>) -> Option<StaticFile> {
    let rel_path = rel_path.strip_prefix('/').unwrap_or(rel_path);
    if !is_safe_rel_path(rel_path) {
        return None;
    }

    let (content_type, compressible) = content_type_and_compressible(rel_path);
    let base_dir = STATIC_DIR.as_str();
    let mut full = String::with_capacity(base_dir.len() + 1 + rel_path.len() + 3);
    full.push_str(base_dir);
    full.push('/');
    full.push_str(rel_path);
    let base_len = full.len();

    if compressible {
        let (accepts_br, accepts_gzip) = parse_accept_encoding(accept_encoding);
        if accepts_br {
            full.push_str(".br");
            if let Ok(data) = fs::read(&full) {
                return Some(StaticFile {
                    content_type,
                    content_encoding: Some(ENC_BR),
                    body: Bytes::from(data),
                });
            }
            full.truncate(base_len);
        }
        if accepts_gzip {
            full.push_str(".gz");
            if let Ok(data) = fs::read(&full) {
                return Some(StaticFile {
                    content_type,
                    content_encoding: Some(ENC_GZIP),
                    body: Bytes::from(data),
                });
            }
            full.truncate(base_len);
        }
    }

    let data = fs::read(&full).ok()?;
    Some(StaticFile {
        content_type,
        content_encoding: None,
        body: Bytes::from(data),
    })
}

pub async fn static_handler(
    Path(path): Path<String>,
    headers: HeaderMap,
) -> Result<Response, StatusCode> {
    let ae = headers.get(ACCEPT_ENCODING).and_then(|v| v.to_str().ok());
    let file = read_static(&path, ae).ok_or(StatusCode::NOT_FOUND)?;
    if let Some(enc) = file.content_encoding {
        Ok((
            [
                (CONTENT_TYPE, file.content_type),
                (CONTENT_ENCODING, enc),
                (VARY, VARY_AE),
            ],
            file.body,
        )
            .into_response())
    } else {
        Ok(([(CONTENT_TYPE, file.content_type)], file.body).into_response())
    }
}
