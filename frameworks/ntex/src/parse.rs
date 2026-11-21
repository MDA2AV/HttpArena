//! `POST /parse`: the resilience suite's parser sink
//! (site/content/docs/test-profiles/resilience/attacks.md). Each body goes
//! through the ntex extractor its Content-Type names; the extractors decode
//! Content-Encoding as they read and stop at their own size limits, so the
//! suite's parser attacks measure ntex's defaults.

use std::collections::HashMap;

use ntex::http::{RequestHead, header};
use ntex::util::Bytes;
use ntex::web::{self, HttpRequest, HttpResponse, guard};

pub fn routes(cfg: &mut web::ServiceConfig<()>) {
    cfg.service(
        web::resource("/parse")
            .route(web::post().guard(content_type("application/json")).to(json))
            .route(
                web::post()
                    .guard(content_type("application/x-www-form-urlencoded"))
                    .to(form),
            )
            .route(web::post().to(other)),
    );
}

/// Matches a request whose Content-Type starts with `essence`, in any case.
fn content_type(essence: &'static str) -> impl guard::Guard {
    guard::fn_guard(move |head: &RequestHead| {
        head.headers
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.as_bytes().get(..essence.len()))
            .is_some_and(|v| v.eq_ignore_ascii_case(essence.as_bytes()))
    })
}

/// `Json` reads at most 32 KiB by default.
async fn json(_: web::types::Json<serde_json::Value>) -> HttpResponse {
    HttpResponse::Ok().content_type("text/plain").body("ok")
}

/// `Form` reads at most 16 KiB by default.
async fn form(_: web::types::Form<HashMap<String, String>>) -> HttpResponse {
    HttpResponse::Ok().content_type("text/plain").body("ok")
}

/// Any other body is read whole, decoded, up to the app's payload limit.
/// ntex has no multipart parser of its own, so a multipart body is split on
/// its boundary, which opens every part and closes the body; the part count
/// is the response.
async fn other(req: HttpRequest, body: Bytes) -> HttpResponse {
    let boundary = req
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split_once("boundary="))
        .map(|(_, rest)| {
            let name = rest.split(';').next().unwrap_or_default();
            format!("--{}", name.trim().trim_matches('"'))
        });
    let parts = boundary.map_or(0, |b| {
        body.windows(b.len())
            .filter(|w| *w == b.as_bytes())
            .count()
            .saturating_sub(1)
    });
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(parts.to_string())
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;
    use ntex::http::StatusCode;
    use ntex::web::App;
    use ntex::web::test::{self, TestRequest};

    fn gzip(data: &[u8]) -> Vec<u8> {
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        enc.write_all(data).unwrap();
        enc.finish().unwrap()
    }

    fn post(ctype: &str, body: Vec<u8>) -> TestRequest {
        TestRequest::post()
            .uri("/parse")
            .header(header::CONTENT_TYPE, ctype)
            .payload(body)
    }

    /// STATEMENT: `/parse` reads each body through the ntex extractor its
    /// Content-Type names, decoding its Content-Encoding first.
    ///
    /// HOW:
    /// - POST a form and a JSON document; confirm `200`.
    /// - POST malformed JSON; confirm `400`.
    /// - POST a form and a JSON document above the extractors' limits
    ///   (16 KiB and 32 KiB); confirm `413`.
    /// - POST a three-part multipart body, plain and gzip-encoded; confirm the
    ///   part count `3` both times.
    /// - With a 64 KiB payload limit, POST a gzip body that inflates to 1 MiB;
    ///   confirm `413`.
    #[ntex::test]
    async fn parse_route() {
        let app = test::init_service(App::new().configure(routes)).await;

        let form = "application/x-www-form-urlencoded";
        let large_form = (0..4000)
            .map(|i| format!("k{i}=1"))
            .collect::<Vec<_>>()
            .join("&");
        let deep_json = format!("{}{}", "[".repeat(20_000), "]".repeat(20_000));
        let multipart = "multipart/form-data; boundary=xyz";
        let parts = "--xyz\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nx\r\n".repeat(3)
            + "--xyz--\r\n";

        for (request, status, body) in [
            (post(form, b"a=1".to_vec()), StatusCode::OK, Some("ok")),
            (
                post("application/json", br#"{"a":[1,2]}"#.to_vec()),
                StatusCode::OK,
                Some("ok"),
            ),
            (
                post("application/json", b"{".to_vec()),
                StatusCode::BAD_REQUEST,
                None,
            ),
            (
                post(form, large_form.into_bytes()),
                StatusCode::PAYLOAD_TOO_LARGE,
                None,
            ),
            (
                post("application/json", deep_json.into_bytes()),
                StatusCode::PAYLOAD_TOO_LARGE,
                None,
            ),
            (
                post(multipart, parts.clone().into_bytes()),
                StatusCode::OK,
                Some("3"),
            ),
            (
                post(multipart, gzip(parts.as_bytes())).header(header::CONTENT_ENCODING, "gzip"),
                StatusCode::OK,
                Some("3"),
            ),
        ] {
            let response = app.call(request.to_request()).await.unwrap();
            assert_eq!(response.status(), status);
            if let Some(body) = body {
                assert_eq!(test::read_body(response).await, body);
            }
        }

        let app = test::init_service(
            App::new()
                .with_config(
                    web::WebAppConfig::new().set_value(web::types::PayloadConfig::new(64 * 1024)),
                )
                .configure(routes),
        )
        .await;
        let bomb = post("application/octet-stream", gzip(&vec![0; 1024 * 1024]))
            .header(header::CONTENT_ENCODING, "gzip");
        let response = app.call(bomb.to_request()).await.unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }
}
