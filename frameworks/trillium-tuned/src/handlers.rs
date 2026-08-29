//! HTTP endpoint handlers, split by section:
//!
//! - [`h1`] — `/pipeline`, `/baseline11`, `/baseline2`, `/json/:count`, `/echo`
//! - [`db`] — `/async-db`
//! - [`crud`] — `/crud/items` and `/crud/items/:id`
//! - [`fortunes`] — `/fortunes`
//! - [`ws`] — `/ws` echo

mod crud;
mod db;
mod fortunes;
mod h1;
mod ws;

pub use crud::{crud_create, crud_list, crud_read, crud_update};
pub use db::async_db;
pub use fortunes::fortunes;
pub use h1::{baseline_any, baseline_get, echo_body, json_handler, pipeline};
use querystrong::QueryStrong;
use trillium::{Conn, KnownHeaderName, Status};
pub use ws::ws_echo;

const TEXT_PLAIN: &str = "text/plain";
const APPLICATION_JSON: &str = "application/json";
const OCTET_STREAM: &str = "application/octet-stream";

fn sum_query_values(q: &str) -> i64 {
    QueryStrong::parse(q)
        .as_map()
        .into_iter()
        .flat_map(|m| m.values())
        .filter_map(|v| v.as_str().and_then(|s| s.parse::<i64>().ok()))
        .sum()
}

fn plain_text<S: Into<String>>(conn: Conn, body: S) -> Conn {
    conn.with_status(Status::Ok)
        .with_response_header(KnownHeaderName::ContentType, TEXT_PLAIN)
        .with_body(body.into())
        .halt()
}

fn octet_stream(conn: Conn, body: Vec<u8>) -> Conn {
    conn.with_status(Status::Ok)
        .with_response_header(KnownHeaderName::ContentType, OCTET_STREAM)
        .with_body(body)
        .halt()
}

fn json_response(conn: Conn, body: Vec<u8>) -> Conn {
    conn.with_status(Status::Ok)
        .with_response_header(KnownHeaderName::ContentType, APPLICATION_JSON)
        .with_body(body)
        .halt()
}
