use crate::{
    handlers::{json_response, octet_stream, plain_text, sum_query_values},
    state::{AppState, Item},
};
use querystrong::QueryStrong;
use serde::Serialize;
use std::{sync::Arc, time::Duration};
use trillium::{Conn, Status};
use trillium_router::RouterConnExt;
use trillium_tokio::tokio::time::sleep;

pub async fn pipeline(conn: Conn) -> Conn {
    plain_text(conn, "ok")
}

/// `GET /delay/:ms` — wait the number of milliseconds named in the path, then echo it back.
///
/// The point of the profile is what the server does with a request it cannot answer yet, so
/// the wait has to suspend the task rather than the thread. `tokio::time::sleep` through
/// trillium-tokio's re-export is what a trillium-on-tokio application would reach for.
pub async fn delay(conn: Conn) -> Conn {
    let ms: u64 = conn.param("ms").and_then(|s| s.parse().ok()).unwrap_or(0);
    sleep(Duration::from_millis(ms)).await;
    plain_text(conn, ms.to_string())
}

pub async fn baseline_get(conn: Conn) -> Conn {
    let sum = sum_query_values(conn.querystring());
    plain_text(conn, sum.to_string())
}

pub async fn baseline_post(mut conn: Conn) -> Conn {
    let mut sum = sum_query_values(conn.querystring());
    if let Ok(body) = conn.request_body_string().await {
        if let Ok(n) = body.trim().parse::<i64>() {
            sum += n;
        }
    }
    plain_text(conn, sum.to_string())
}

pub async fn baseline_any(conn: Conn) -> Conn {
    if conn.method() == trillium::Method::Post {
        baseline_post(conn).await
    } else {
        baseline_get(conn).await
    }
}

pub async fn echo_body(mut conn: Conn) -> Conn {
    // Echo: read the body to end regardless of framing and hand the same bytes back.
    // `read_bytes` preallocates from Content-Length (up to the config's max-preallocate),
    // so the benchmark's CL-framed bodies land in a single exact-size allocation; chunked
    // bodies are decoded by the same path.
    match conn.request_body().read_bytes().await {
        Ok(body) => octet_stream(conn, body),
        Err(_) => conn.with_status(Status::BadRequest).halt(),
    }
}

#[cfg(test)]
mod tests {
    use super::echo_body;
    use trillium::Body;
    use trillium_testing::TestServer;

    /// Patterned rather than constant, so a truncated, reordered, or canned echo cannot pass.
    fn patterned_body(len: usize) -> Vec<u8> {
        (0..len)
            .map(|i| (i.wrapping_mul(31).wrapping_add(7)) as u8)
            .collect()
    }

    #[test]
    fn content_length_bodies_echo_byte_for_byte() {
        let app = TestServer::new_blocking(echo_body);
        // validate.sh's sizes: 10240 is the benchmark's own, 102400 is deliberately larger.
        for len in [1, 1024, 10240, 102400] {
            let body = patterned_body(len);
            let conn = app.post("/echo").with_body(body.clone()).block();
            conn.assert_ok();
            assert_eq!(conn.body_bytes(), body, "{len}B body did not round-trip");
        }
    }

    #[test]
    fn chunked_bodies_echo_byte_for_byte() {
        let app = TestServer::new_blocking(echo_body);
        // A streaming body with no length is sent with chunked framing, so the bytes
        // have to come back out of the chunk decoder rather than a Content-Length.
        for len in [10240, 102400] {
            let body = patterned_body(len);
            let conn = app
                .post("/echo")
                .with_body(Body::new_streaming(
                    futures_lite::io::Cursor::new(body.clone()),
                    None,
                ))
                .block();
            conn.assert_ok();
            assert_eq!(conn.body_bytes(), body, "chunked {len}B body did not round-trip");
        }
    }

    #[test]
    fn empty_body_echoes_as_200() {
        let app = TestServer::new_blocking(echo_body);
        let conn = app.post("/echo").block();
        conn.assert_ok();
        assert!(conn.body_bytes().is_empty());
    }
}

pub async fn json_handler(conn: Conn) -> Conn {
    let count: usize = conn
        .param("count")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let qs = QueryStrong::parse(conn.querystring());
    let m: i64 = qs.get_str("m").and_then(|s| s.parse().ok()).unwrap_or(1);
    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));
    let take = count.min(state.dataset.len());

    #[derive(Serialize)]
    struct ItemView<'a> {
        #[serde(flatten)]
        item: &'a Item,
        total: i64,
    }

    #[derive(Serialize)]
    struct Resp<'a> {
        items: Vec<ItemView<'a>>,
        count: usize,
    }

    let items = state.dataset[..take]
        .iter()
        .map(|item| ItemView {
            item,
            total: i64::from(item.price) * i64::from(item.quantity) * m,
        })
        .collect::<Vec<_>>();

    let body = sonic_rs::to_vec(&Resp { items, count: take }).unwrap_or_default();
    json_response(conn, body)
}
