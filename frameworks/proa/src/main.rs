mod fortunes;

use std::{env, time::Duration};

use arrayvec::ArrayVec;
use axum::{
    Router,
    body::Bytes,
    extract::{Path, Query, State},
    http::{StatusCode, header::CONTENT_TYPE},
    response::{Html, IntoResponse},
    routing::get,
};
use deadpool_postgres::{Manager, Pool, tokio_postgres::NoTls};
use proa::{WebContext, WebRenderSync};
use serde::Deserialize;
use tokio::{net::TcpListener, time::sleep};

use crate::fortunes::{Fortune, Fortunes};

const FORTUNE_COUNT: usize = 201;
const ADDITIONAL_FORTUNE: &str = "Additional fortune added at request time.";

#[derive(Deserialize)]
struct BaselineQuery {
    a: i64,
    b: i64,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let pool = match env::var("DATABASE_URL") {
        Ok(url) => {
            let max_connections = match env::var("DATABASE_MAX_CONN") {
                Ok(limit) => limit.parse()?,
                Err(env::VarError::NotPresent) => 256,
                Err(error) => return Err(error.into()),
            };
            let manager = Manager::new(url.parse()?, NoTls);
            Some(Pool::builder(manager).max_size(max_connections).build()?)
        }
        Err(env::VarError::NotPresent) => None,
        Err(error) => return Err(error.into()),
    };
    let app = Router::new()
        .route("/baseline11", get(baseline_get).post(baseline_post))
        .route("/pipeline", get(|| async { "ok" }))
        .route("/delay/{ms}", get(delay))
        .route("/fortunes", get(fortunes))
        .with_state(pool);

    axum::serve(TcpListener::bind("0.0.0.0:8080").await?, app).await?;
    Ok(())
}

async fn baseline_get(Query(query): Query<BaselineQuery>) -> Result<impl IntoResponse, StatusCode> {
    baseline_response(query, 0)
}

async fn baseline_post(
    Query(query): Query<BaselineQuery>,
    body: Bytes,
) -> Result<impl IntoResponse, StatusCode> {
    let body_value = std::str::from_utf8(&body)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .ok_or(StatusCode::BAD_REQUEST)?;
    baseline_response(query, body_value)
}

fn baseline_response(
    query: BaselineQuery,
    body_value: i64,
) -> Result<impl IntoResponse, StatusCode> {
    let sum = query
        .a
        .checked_add(query.b)
        .and_then(|sum| sum.checked_add(body_value))
        .ok_or(StatusCode::BAD_REQUEST)?;
    Ok(text_number(sum))
}

fn text_number(value: impl itoa::Integer) -> impl IntoResponse {
    let mut buffer = itoa::Buffer::new();
    (
        [(CONTENT_TYPE, "text/plain")],
        Bytes::copy_from_slice(buffer.format(value).as_bytes()),
    )
}

async fn delay(Path(milliseconds): Path<u64>) -> impl IntoResponse {
    if milliseconds != 0 {
        sleep(Duration::from_millis(milliseconds)).await;
    }
    text_number(milliseconds)
}

async fn fortunes(State(pool): State<Option<Pool>>) -> Result<Html<Vec<u8>>, StatusCode> {
    let pool = pool.ok_or(StatusCode::SERVICE_UNAVAILABLE)?;
    let rows = {
        let client = pool.get().await.map_err(database_error)?;
        let statement = client
            .prepare_cached("SELECT id, message FROM fortune")
            .await
            .map_err(database_error)?;
        client
            .query(&statement, &[])
            .await
            .map_err(database_error)?
    };

    if rows.len() != FORTUNE_COUNT - 1 {
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }

    let mut fortunes = ArrayVec::<_, FORTUNE_COUNT>::new();
    for row in &rows {
        fortunes.push(Fortune {
            id: row.try_get(0).map_err(database_error)?,
            message: row.try_get(1).map_err(database_error)?,
        });
    }
    fortunes.push(Fortune {
        id: 0,
        message: ADDITIONAL_FORTUNE,
    });
    fortunes.sort_unstable_by(|left, right| left.message.cmp(right.message));

    let mut context = WebContext::with_buffer(Vec::with_capacity(32 * 1024));
    Fortunes(&fortunes).render(&mut context).map_err(|error| {
        eprintln!("could not render fortunes: {error}");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;
    Ok(Html(context.into_output()))
}

fn database_error(error: impl std::fmt::Display) -> StatusCode {
    eprintln!("could not load fortunes: {error}");
    StatusCode::INTERNAL_SERVER_ERROR
}
