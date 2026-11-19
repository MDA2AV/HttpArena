use std::ops::Add;

use ruvel::{
    http::{Method, Response, Status},
    routing::Router,
};

use crate::app::http::controllers::HttpArenaController;

pub fn routes(router: &mut Router) {
    // Benchmarks: baseline, latency_1m, latency_10k, latency_500k_8cpu, limited_conn
    router.get("baseline11", async move |req| {
        HttpArenaController.baseline(req).await
    });

    router.post("baseline11", async move |req| {
        Response::new(Status::Ok).text(
            req.u32("a")
                .unwrap_or_default()
                .add(req.u32("b").unwrap_or_default())
                .add(
                    str::from_utf8(&req.body)
                        .unwrap_or_default()
                        .parse::<u32>()
                        .unwrap_or_default(),
                )
                .to_string(),
        )
    });

    router.get("baseline11", async move |req| {
        HttpArenaController.baseline(req).await
    });

    // Benchmarks: Pipelined
    router.get("pipeline", async move |req| {
        HttpArenaController.pipelined(req).await
    });

    // Benchmarks: Async
    router.get("delay/{ms}", async move |req| {
        HttpArenaController.r#async(req).await
    });

    router.get("spec", async |_req| {
        Response::new(Status::Ok)
            .text("5 bytes")
            .header("Content-Type", "text/plain")
    });
    router.head("spec", async |_req| {});

    router.options("spec", async |_req| {
        Response::ok().header("Allow", "GET, HEAD, POST, OPTIONS")
    });

    router.get("spec/headers", async |req| {
        let mut s = String::from("");

        for (name, value) in req.headers() {
            s.push_str(&format!("{}: {}\r\n", name, value));
        }

        Response::new(Status::Ok)
            .text(s)
            .header("Content-Type", "text/plain")
    });

    router.post("spec", async move |_req| {
        Response::new(Status::Ok)
            .text(str::from_utf8(&_req.body).unwrap_or_default())
            .header("Content-Type", "application/octet-stream")
    });

    router.post("spec/headers", async |req| {
        let mut s = String::from("");

        for (name, value) in req.headers() {
            s.push_str(&format!("{}: {}\r\n", name, value));
        }

        Response::new(Status::Ok)
            .text(s)
            .header("Content-Type", "text/plain")
    });
}
