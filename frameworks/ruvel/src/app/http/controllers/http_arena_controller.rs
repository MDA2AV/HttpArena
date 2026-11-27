use std::ops::Add;

use ruvel::http::{Controller, Request, Responsable, Response, Status};
use tokio::time::{Duration, sleep};

#[derive(Default)]
pub struct HttpArenaController;

impl Controller for HttpArenaController {}

impl HttpArenaController {
    pub async fn baseline(&self, request: Request) -> impl Responsable {
        Response::new(Status::Ok).text(
            request
                .u32("a")
                .unwrap_or_default()
                .add(request.u32("b").unwrap_or_default())
                .add(
                    str::from_utf8(&request.body)
                        .unwrap_or_default()
                        .parse::<u32>()
                        .unwrap_or_default(),
                )
                .to_string(),
        )
    }

    pub async fn baseline_post(&self, request: Request) -> impl Responsable {
        Response::new(Status::Ok).text(
            request
                .u32("a")
                .unwrap_or_default()
                .add(request.u32("b").unwrap_or_default())
                .add(
                    str::from_utf8(&request.body)
                        .unwrap_or_default()
                        .parse::<u32>()
                        .unwrap_or_default(),
                )
                .to_string(),
        )
    }

    pub async fn pipelined(&self, _request: Request) -> impl Responsable {
        Response::new(Status::Ok).text("ok")
    }

    pub async fn limited_conn(&self, _request: Request) -> impl Responsable {
        "Welcome to Ruvel Again"
    }

    pub async fn r#async(&self, request: Request) -> impl Responsable {
        let duration = request
            .param("ms")
            .unwrap_or_default()
            .parse::<u16>()
            .unwrap_or_default();

        if duration > 0 {
            sleep(Duration::from_millis(duration as u64)).await;
        }

        Response::new(Status::Ok).text(duration.to_string())
    }

    pub async fn latency_1m(&self, _request: Request) -> impl Responsable {
        "Welcome to Ruvel Again"
    }

    pub async fn latency_10k(&self, _request: Request) -> impl Responsable {
        "Welcome to Ruvel Again"
    }

    pub async fn latency_500k_8cpu(&self, _request: Request) -> impl Responsable {
        "Welcome to Ruvel Again"
    }
}
