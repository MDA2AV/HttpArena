use std::{
    cell::Cell,
    fmt,
    io::{self, Write as _},
    num::TryFromIntError,
    process::ExitCode,
    time::Duration,
};

use dope::{
    core::driver::{route::Identity, schedule::clock::timer::Timer},
    manifold::network::listener::conn,
    net::wire::{open, terminal},
};
use dope_fiber::task::time::sleep::{self, TimerExt as _};
use dope_tls::tls::{Tls, roles};
use sark::http::{
    field::text::{Ascii, IntError},
    payload::response::status::Code,
    request::body,
};
use sark_h1::server::listener::failure;

pub mod boot;
pub mod cache;
pub mod dataset;
pub mod db;
pub mod files;
pub mod grpcbench;
pub mod h3;
pub mod json;
pub mod model;
pub mod runtime;
pub mod tls;
pub mod ws;

pub fn fail(message: fmt::Arguments<'_>) -> ExitCode {
    match writeln!(io::stderr().lock(), "{message}") {
        Ok(()) => ExitCode::FAILURE,
        Err(_) => ExitCode::from(2),
    }
}

fn diagnostic(errors: &Cell<Option<io::Error>>, message: fmt::Arguments<'_>) {
    if let Err(error) = writeln!(io::stderr().lock(), "{message}") {
        errors.set(errors.take().or(Some(error)));
    }
}

pub struct State<'files, 'd, P, R> {
    pub pg: P,
    pub redis: R,
    pub pg_configured: bool,
    pub redis_configured: bool,
    pub cache_tokens: cache::Tokens,
    pub dataset: &'files dataset::Dataset,
    pub files: files::Root<'files, 'd>,
    pub diagnostics: &'files Cell<Option<io::Error>>,
}

impl<P, R> failure::Policy<Tls<roles::Server>> for State<'_, '_, P, R> {
    fn open_failed<'w>(&self, cause: open::Error<'w, Tls<roles::Server>>)
    where
        Tls<roles::Server>: 'w,
    {
        diagnostic(
            self.diagnostics,
            format_args!("TLS open: {:?}", cause.into_cause()),
        );
    }

    fn wire_failed<'w, 'd: 'w, ID: Identity>(
        &self,
        connection: conn::Id<'d, ID>,
        cause: terminal::Error<'w, Tls<roles::Server>>,
    ) {
        let (cause, closing) = cause.into_parts();
        diagnostic(
            self.diagnostics,
            format_args!(
                "TLS connection {}: {cause:?}, closing: {closing:?}",
                connection.index().get(),
            ),
        );
    }
}

#[derive(Debug)]
pub enum Cause {
    Body(IntError),
    Integer(TryFromIntError),
    Sum { left: u64, right: u64 },
    Json(json::Error),
    Delay(sleep::Error),
}

#[sark::response(raw)]
#[header("content-type", "text/plain")]
pub struct Failure {
    status: Code,
    body: &'static [u8],
    pub cause: Cause,
}

impl From<Cause> for Failure {
    fn from(cause: Cause) -> Self {
        let (status, body): (_, &[u8]) = match &cause {
            Cause::Body(_) => (Code::BAD_REQUEST, b"invalid body"),
            Cause::Integer(_) => (Code::BAD_REQUEST, b"integer overflow"),
            Cause::Sum { .. } | Cause::Json(_) => (Code::BAD_REQUEST, b"integer overflow"),
            Cause::Delay(sleep::Error::Duration { .. }) => (Code::BAD_REQUEST, b"invalid delay"),
            Cause::Delay(sleep::Error::Capacity) => (Code::SERVICE_UNAVAILABLE, b"timer capacity"),
        };
        Self {
            status,
            body,
            cause,
        }
    }
}

#[sark::response(json)]
#[header("content-type", "text/plain")]
pub struct Number {
    status: Code,
    body: u64,
}

impl Number {
    fn ok(body: u64) -> Self {
        Self {
            status: Code::OK,
            body,
        }
    }
}

fn sum(left: u64, right: u64) -> Result<u64, Failure> {
    left.checked_add(right)
        .ok_or_else(|| Cause::Sum { left, right }.into())
}

#[sark::request]
pub struct BaselineGet {
    #[query("a", default = "0")]
    a: u64,
    #[query("b", default = "0")]
    b: u64,
}

#[sark::handler(pub)]
pub fn baseline_get(request: BaselineGet) -> Result<Number, Failure> {
    Ok(Number::ok(sum(request.a, request.b)?))
}

#[sark::request]
pub struct BaselinePost {
    #[query("a", default = "0")]
    a: u64,
    #[query("b", default = "0")]
    b: u64,
    #[raw_body]
    payload: Shared,
}

#[sark::handler(pub)]
pub fn baseline_post(request: BaselinePost) -> Result<Number, Failure> {
    let value = Ascii::new(request.payload)
        .parse_u64()
        .map_err(Cause::Body)?;
    Ok(Number::ok(sum(sum(request.a, request.b)?, value)?))
}

#[sark::response(raw)]
#[header("content-type", "text/plain")]
pub struct Plain {
    status: Code,
    body: &'static [u8],
}

#[sark::handler(pub)]
pub fn pipeline() -> Plain {
    Plain {
        status: Code::OK,
        body: b"ok",
    }
}

#[sark::request]
pub struct DelayRequest {
    #[path]
    ms: usize,
}

#[sark::handler(pub)]
pub async fn delay(request: DelayRequest, timer: Timer<'_>) -> Result<Number, Failure> {
    let ms = u64::try_from(request.ms).map_err(Cause::Integer)?;
    timer
        .sleep(Duration::from_millis(ms))
        .map_err(Cause::Delay)?
        .await;
    Ok(Number::ok(ms))
}

#[sark::request]
pub struct JsonRequest {
    #[path]
    count: usize,
    #[query("m", default = "1")]
    multiplier: u64,
}

#[sark::handler(pub)]
pub fn json_endpoint<'files, P, R>(
    request: JsonRequest,
    state: &State<'files, '_, P, R>,
) -> Result<sark_json::writing::Response<json::Listing<'files>>, Failure> {
    let listing =
        json::items(state.dataset, request.count, request.multiplier).map_err(Cause::Json)?;
    sark_json::writing::Body::new(listing)
        .try_response()
        .map_err(|error| match error.discard() {})
}

#[sark::request]
pub struct EchoRequest {
    #[raw_body]
    payload: owned::Segments,
}

#[sark::response(raw)]
#[header("content-type", "application/octet-stream")]
pub struct Echo<'req, 'd> {
    status: Code,
    body: body::Ref<'req, 'd>,
}

#[sark::handler(pub)]
#[max_body(32 * 1024 * 1024)]
pub fn echo(request: EchoRequest) -> Echo<'req, 'd> {
    Echo {
        status: Code::OK,
        body: request.payload,
    }
}

sark_fiber::define_cleartext_route! {
    pub App<'files, P, R>: State<'files, '_, P, R>
    where P: cartel_pg::api::traits::Client<'_, 10, Schema = db::Db>,
          R: cartel_redis::api::Client<'_, 11>
    => {
        GET "/baseline11" => request(query) baseline_get,
        POST "/baseline11" => request(query) baseline_post,
        GET "/baseline2" => request(query) baseline_get,
        POST "/baseline2" => request(query) baseline_post,
        GET "/public/baseline" => request(query) baseline_get,
        GET "/pipeline" => pipeline,
        WS "/ws" => ws::open,
        GET "/delay/:ms" => request(path) async(capacity = global, body = discarded) delay,
        GET "/json/:count" => request(path, query) json_endpoint,
        GET "/public/json/:count" => request(path, query) json_endpoint,
        POST "/echo" => echo,
        GET "/async-db" => request(query) async(capacity = global, body = discarded) db::async_db,
        GET "/fortunes" => async(capacity = global, body = discarded) db::fortunes,
        GET "/api/items/:id" => request(path) async(capacity = global, body = discarded) db::item,
        POST "/api/items/:id" => request(path) async(capacity = global, body = json) db::update,
        GET "/api/me" => request(header) async(capacity = global, body = discarded) db::me,
        GET "/static/:file" => request(path, header) async stream(capacity = global, body = discarded) files::static_endpoint,
    }
}
