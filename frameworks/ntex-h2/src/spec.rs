//! `/spec` and `/spec/headers`: the route the compliance suites probe
//! (site/content/docs/test-profiles/compliance/), on both listeners. Nothing
//! on it is measured.

use ntex::http::{Method, header};
use ntex::util::Bytes;
use ntex::web::{self, HttpRequest, HttpResponse};

/// GET answers a fixed body of at least five bytes, h2spec skips a
/// flow-control test below that. HEAD has a route of its own, since a GET
/// route does not match it; ntex ends a HEAD response's stream after the
/// headers itself. POST echoes the body.
pub fn routes(cfg: &mut web::ServiceConfig<()>) {
    cfg.service(
        web::resource("/spec")
            .route(web::get().to(text))
            .route(web::head().to(text))
            .route(web::method(Method::OPTIONS).to(options))
            .route(web::post().to(echo)),
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

async fn echo(body: Bytes) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("application/octet-stream")
        .body(body)
}

/// Every request header as ntex stored it, one `Name: Value` line per value.
/// A request body is read and discarded.
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
