use crate::{
    handlers::{json_response, plain_text, sum_query_values},
    state::{AppState, Item},
};
use futures_lite::AsyncReadExt;
use querystrong::QueryStrong;
use serde::Serialize;
use std::sync::Arc;
use trillium::{Conn, Status};
use trillium_router::RouterConnExt;

pub async fn pipeline(conn: Conn) -> Conn {
    plain_text(conn, "ok")
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

pub async fn upload(mut conn: Conn) -> Conn {
    let mut total: u64 = 0;
    let mut buf = vec![0u8; 64 * 1024];
    let mut errored = false;
    {
        let mut body = conn.request_body();
        loop {
            match body.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => total += n as u64,
                Err(_) => {
                    errored = true;
                    break;
                }
            }
        }
    }
    if errored {
        conn.with_status(Status::BadRequest).halt()
    } else {
        plain_text(conn, total.to_string())
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
