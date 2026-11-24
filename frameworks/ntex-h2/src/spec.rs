//! `/spec` and `/spec/headers`: the route the compliance suites probe
//! (site/content/docs/test-profiles/compliance/), on both listeners. Nothing
//! on it is measured.

use ntex::http::{Method, header};
use ntex::util::Bytes;
use ntex::web::{self, HttpRequest, HttpResponse};

/// GET answers a fixed body of at least five bytes, h2spec skips a
/// flow-control test below that. HEAD has a route of its own, since a GET
/// route does not match it; ntex ends a HEAD response's stream after the
/// headers itself. POST echoes the body. GET and HEAD read the request body
/// before answering, see [`text`].
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

/// The request body is read and discarded before answering.
///
/// ntex hands each frame to the service as soon as it is decoded and polls
/// the handler once right away. A handler that does not take the body is
/// done on that first poll, before ntex decodes the frames that follow, so
/// the response (HEADERS, then DATA with END_STREAM) goes out while the
/// client has not ended the request yet. Nothing holds the request body
/// any more, so ntex then sends RST_STREAM(NO_ERROR) to tell the client to
/// stop sending it. The stream is closed now, and a WINDOW_UPDATE that
/// arrives after that is ignored. Both steps are allowed by RFC 9113 (§8.1
/// and §5.1).
///
/// h2spec http2/6.9/2 and http2/6.9.1/3 send HEADERS without END_STREAM,
/// then an invalid WINDOW_UPDATE on the stream, and expect a stream error
/// (PROTOCOL_ERROR or FLOW_CONTROL_ERROR), so the NO_ERROR reset fails
/// them. Taking the body keeps the stream open until the client ends it,
/// and ntex answers the WINDOW_UPDATE with the stream error.
async fn text(_: Bytes) -> HttpResponse {
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
