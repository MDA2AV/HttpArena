//! `/spec` and `/spec/headers`: the route the compliance suites probe
//! (site/content/docs/test-profiles/compliance/). Nothing on it is measured.

use ntex::http::{Method, header};
use ntex::util::Bytes;
use ntex::web::{self, HttpRequest, HttpResponse};

/// GET answers a fixed body of at least five bytes. HEAD has a route of its
/// own, since a GET route does not match it; ntex drops the body of a HEAD
/// response itself. POST is the `/echo` handler.
pub fn routes(cfg: &mut web::ServiceConfig<()>) {
    cfg.service(
        web::resource("/spec")
            .route(web::get().to(text))
            .route(web::head().to(text))
            .route(web::method(Method::OPTIONS).to(options))
            .route(web::post().to(crate::echo_body)),
    )
    .service(
        web::resource("/spec/headers")
            .route(web::get().to(headers))
            .route(web::post().to(headers)),
    );
}

async fn text() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain")
        .body("spec ok")
}

/// A request body is read and discarded.
async fn options(_: Bytes) -> HttpResponse {
    HttpResponse::Ok()
        .header(header::ALLOW, "GET, HEAD, POST, OPTIONS")
        .build()
}

/// Every request header as ntex stored it, one `Name: Value` line per value.
/// The probe's normalization tests read this back to see what became of a
/// malformed header name. A request body is read and discarded.
async fn headers(req: HttpRequest, _: Bytes) -> HttpResponse {
    let mut out = String::new();
    for (name, value) in req.headers() {
        out.push_str(name.as_str());
        out.push_str(": ");
        out.push_str(&String::from_utf8_lossy(value.as_bytes()));
        out.push('\n');
    }
    HttpResponse::Ok().content_type("text/plain").body(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ntex::http::StatusCode;
    use ntex::web::App;
    use ntex::web::test::{self, TestRequest};

    /// STATEMENT: `/spec` answers GET, HEAD, OPTIONS and POST the way the
    /// compliance suites expect, and `/spec/headers` lists the request headers.
    ///
    /// HOW:
    /// - GET and HEAD `/spec`; confirm `200` and `text/plain`, and `spec ok`
    ///   for GET (the h1 codec, not the handler, drops the HEAD body).
    /// - OPTIONS `/spec` with a body; confirm `200` and the `Allow` header.
    /// - POST a binary body to `/spec`; confirm it comes back unchanged.
    /// - GET and POST `/spec/headers` with `X-Spec-Probe`; confirm the line.
    #[ntex::test]
    async fn spec_route() {
        let app = test::init_service(App::new().configure(routes)).await;

        for method in [Method::GET, Method::HEAD] {
            let request = TestRequest::default()
                .method(method.clone())
                .uri("/spec")
                .to_request();
            let response = app.call(request).await.unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{method}");
            assert_eq!(
                response.headers().get(header::CONTENT_TYPE).unwrap(),
                "text/plain"
            );
            if method == Method::GET {
                assert_eq!(test::read_body(response).await, "spec ok");
            }
        }

        let request = TestRequest::default()
            .method(Method::OPTIONS)
            .uri("/spec")
            .payload("read and discarded")
            .to_request();
        let response = app.call(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(header::ALLOW).unwrap(),
            "GET, HEAD, POST, OPTIONS"
        );

        let payload: Vec<u8> = (0..=255).cycle().take(4096).collect();
        let request = TestRequest::post()
            .uri("/spec")
            .payload(payload.clone())
            .to_request();
        let response = app.call(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(test::read_body(response).await, payload);

        for request in [TestRequest::get(), TestRequest::post().payload("discarded")] {
            let request = request
                .uri("/spec/headers")
                .header("X-Spec-Probe", "probe-42")
                .to_request();
            let response = app.call(request).await.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let body = test::read_body(response).await;
            let body = std::str::from_utf8(&body).unwrap();
            assert!(
                body.lines().any(|l| l == "x-spec-probe: probe-42"),
                "{body}"
            );
        }
    }
}
