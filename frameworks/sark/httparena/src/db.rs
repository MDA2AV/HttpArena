use std::{
    collections::TryReserveError,
    convert::Infallible,
    num::{NonZero, ParseIntError, TryFromIntError},
    str::{self, Utf8Error},
};

use cartel_pg::{
    Jsonb, PgRow, PgTable,
    api::traits::Client as PgClient,
    pg_instance,
    port::config,
    query_group, reply,
};
use cartel_redis::{
    api::{Client as RedisClient, Commands as _},
    client::nonempty,
};
use dope::{
    manifold::client::{attempt::ConnectFault, close, conn},
    net::link::event::ConnectError,
};
use o3::{
    buffer::{
        storage::{self, Shared},
        write::consume,
    },
    mem::Rejected,
};
use sark::http::{
    field::{self, Value},
    payload::{
        fixed,
        response::{self, dispatch::Either, exact, exact::Overflow, status::Code},
    },
};
use sark_json::{
    Raw,
    writing::{self, TryEncode},
};

use crate::cache::{self, Key};

pub const ID: u8 = 10;
pub const TASKS: usize = 64;
pub const MAX_BODY_BYTES: usize = 1024 * 1024;
const MAX_FORTUNES: usize = 4096;
const MISS: Value<&'static [u8]> = field::literal!(Value::try_bytes(b"MISS"));

#[derive(PgTable, PgRow)]
#[table_name("items")]
pub struct ItemRow {
    pub id: i32,
    pub name: String,
    pub category: String,
    pub price: i32,
    pub quantity: i32,
    pub active: bool,
    pub tags: Jsonb,
    pub rating_score: i32,
    pub rating_count: i32,
}

#[query_group]
impl ItemRow {
    pub fn by_id(id: i32) -> ItemRow {
        ItemRow::filter(|item| item.id == id).one()
    }

    pub fn range(min: i32, max: i32, limit: i64) -> Vec<ItemRow> {
        ItemRow::filter(|item| item.price >= min && item.price <= max)
            .limit(limit)
            .all()
    }

    pub fn update_fields(id: i32, name: &str, price: i32, quantity: i32) -> ItemRow {
        ItemRow::filter(|item| item.id == id)
            .update(|item| {
                item.name = name;
                item.price = price;
                item.quantity = quantity;
            })
            .returning_one()
    }
}

#[derive(PgTable, PgRow)]
#[table_name("fortune")]
pub struct Fortune {
    pub id: i32,
    pub message: String,
}

#[query_group]
impl Fortune {
    pub fn all_rows() -> Vec<Fortune> {
        Fortune::filter(|_fortune| true).all()
    }
}

#[derive(PgTable, PgRow)]
#[table_name("users")]
pub struct User {
    pub id: i32,
    pub name: String,
    pub email: String,
    pub plan: String,
}

#[query_group]
impl User {
    pub fn by_id(id: i32) -> User {
        User::filter(|user| user.id == id).one()
    }
}

pg_instance! { pub Db: ItemRow, Fortune, User }

#[sark_json::json(try_encode)]
struct Rating {
    score: i64,
    count: i64,
}

#[sark_json::json(try_encode)]
struct Item<'a> {
    id: i64,
    name: &'a [u8],
    category: &'a [u8],
    price: i64,
    quantity: i64,
    active: bool,
    #[field(raw)]
    tags: &'a [u8],
    #[field(nested)]
    rating: Rating,
}

impl<'a> Item<'a> {
    fn try_from_row(row: ItemRowView<'a>) -> Result<Self, BodyError> {
        Ok(Self {
            id: i64::from(row.id),
            name: row.name.into(),
            category: row.category.into(),
            price: i64::from(row.price),
            quantity: i64::from(row.quantity),
            active: row.active,
            tags: Raw::try_new(row.tags.as_bytes())
                .map_err(Rejected::discard)
                .map_err(BodyError::Json)?,
            rating: Rating {
                score: i64::from(row.rating_score),
                count: i64::from(row.rating_count),
            },
        })
    }
}

#[sark_json::json(try_encode)]
struct Items<'a> {
    #[field(seq, nested)]
    items: Vec<Item<'a>>,
    count: u64,
}

#[sark_json::json(try_encode)]
struct UserBody<'a> {
    id: i64,
    name: &'a [u8],
    email: &'a [u8],
    plan: &'a [u8],
}

#[sark::response(raw)]
#[header("content-type", "application/json")]
pub struct JsonResponse<B = storage::Shared>
where
    B: for<'body> response::Body<'body>,
{
    pub status: Code,
    pub body: B,
}

#[sark::response(raw)]
#[header("content-type", "application/json")]
pub struct CachedResponse {
    pub status: Code,
    #[header("x-cache")]
    pub cache: Value<&'static [u8]>,
    pub body: storage::Shared,
}

#[sark::response(raw)]
#[header("content-type", "text/html; charset=UTF-8")]
pub struct HtmlResponse {
    pub status: Code,
    pub body: Vec<u8>,
}

#[sark::response(raw)]
pub struct NoContent {
    pub status: Code,
    pub body: &'static [u8],
}

#[derive(Debug)]
pub enum BodyError {
    Json(sark_json::Error),
    Size(Overflow),
    Build(storage::BuildError<consume::Error>),
    Allocation(TryReserveError),
    Count(TryFromIntError),
    EscapeSize { bytes: usize },
    Limit { actual: usize, maximum: usize },
}

pub enum Cause<'region, E> {
    Integer(TryFromIntError),
    Number(NumberError),
    Identity,
    Name,
    Pg(reply::Error<'region, ID>),
    Decode(cartel_pg::Error),
    Cache(E),
    Token(cache::Exhausted),
    Unavailable(Upstream),
    Body(BodyError),
}

#[derive(Debug)]
pub enum Upstream {
    Postgres,
    Redis,
}

#[derive(Debug)]
pub enum NumberError {
    Utf8(Utf8Error),
    Parse(ParseIntError),
}

#[sark::response(raw)]
#[header("content-type", "text/plain; charset=UTF-8")]
pub struct Error<'region, E> {
    pub status: Code,
    pub cause: Cause<'region, E>,
    pub body: &'static [u8],
}

impl<'region, E> Error<'region, E> {
    fn require(configured: bool, upstream: Upstream) -> Result<(), Self> {
        if configured {
            return Ok(());
        }
        Err(Self {
            status: Code::SERVICE_UNAVAILABLE,
            cause: Cause::Unavailable(upstream),
            body: b"upstream is not configured",
        })
    }

    fn pg(error: reply::Error<'region, ID>) -> Self {
        let status = match error.as_driver() {
            Some(cartel_pg::Error::NotFound) => Code::NOT_FOUND,
            _ => Code::BAD_GATEWAY,
        };
        Self {
            status,
            cause: Cause::Pg(error),
            body: b"database request failed",
        }
    }

    fn decode(error: cartel_pg::Error) -> Self {
        Self {
            status: Code::BAD_GATEWAY,
            cause: Cause::Decode(error),
            body: b"invalid database reply",
        }
    }

    fn cache(error: impl Into<E>) -> Self {
        Self {
            status: Code::BAD_GATEWAY,
            cause: Cause::Cache(error.into()),
            body: b"cache request failed",
        }
    }

    fn integer(error: TryFromIntError) -> Self {
        Self {
            status: Code::BAD_REQUEST,
            cause: Cause::Integer(error),
            body: b"invalid integer",
        }
    }

    fn name() -> Self {
        Self {
            status: Code::BAD_REQUEST,
            cause: Cause::Name,
            body: b"invalid name",
        }
    }

    fn number(error: NumberError) -> Self {
        Self {
            status: Code::BAD_REQUEST,
            cause: Cause::Number(error),
            body: b"invalid integer",
        }
    }

    fn identity() -> Self {
        Self {
            status: Code::UNAUTHORIZED,
            cause: Cause::Identity,
            body: b"missing user identity",
        }
    }

    fn token(error: cache::Exhausted) -> Self {
        Self {
            status: Code::SERVICE_UNAVAILABLE,
            cause: Cause::Token(error),
            body: b"cache token capacity exhausted",
        }
    }

    fn body(error: BodyError) -> Self {
        let status = if matches!(error, BodyError::Json(_)) {
            Code::BAD_GATEWAY
        } else {
            Code::INTERNAL_SERVER_ERROR
        };
        Self {
            status,
            cause: Cause::Body(error),
            body: b"response encoding failed",
        }
    }
}

#[sark::request]
pub struct RangeRequest {
    #[query("min", default = "10")]
    pub min: Shared,
    #[query("max", default = "50")]
    pub max: Shared,
    #[query("limit", default = "50")]
    pub limit: Shared,
}

#[sark::request]
pub struct ItemRequest {
    #[path]
    pub id: usize,
}

#[sark::request]
pub struct MeRequest {
    #[header("x-user-id")]
    pub id: Option<usize>,
}

#[sark_json::json]
pub struct Update {
    pub name: Shared,
    pub price: i64,
    pub quantity: i64,
}

#[sark::request]
#[json_body(Update)]
pub struct UpdateRequest {
    #[path]
    pub id: usize,
}

#[sark::handler(pub)]
pub async fn async_db<'files, P, R>(
    request: RangeRequest,
    state: &crate::State<'files, '_, P, R>,
) -> Result<Either<JsonResponse, JsonResponse<fixed::Body<'static>>>, Error<'_, Infallible>>
where
    P: PgClient<'_, ID, Schema = Db>,
{
    let min = i32::try_from(number(request.min.as_ref()).map_err(Error::number)?)
        .map_err(Error::integer)?;
    let max = i32::try_from(number(request.max.as_ref()).map_err(Error::number)?)
        .map_err(Error::integer)?;
    let limit = number(request.limit.as_ref())
        .map_err(Error::number)?
        .clamp(1, 50);
    drop(request);
    let empty = || {
        Either::Right(JsonResponse {
            status: Code::OK,
            body: fixed::Body::new(br#"{"items":[],"count":0}"#),
        })
    };
    if !state.pg_configured {
        return Ok(empty());
    }
    let rows = match state.pg.acquire().await {
        Ok(query) => ItemRow::range(query, min, max, limit).await,
        Err(cause) => Err(cause),
    };
    let rows = match rows {
        Ok(rows) => rows,
        Err(cause) => {
            let kind = cause.kind();
            let unavailable = match &kind {
                reply::Kind::Open(reply::Open::Transport {
                    cause:
                        ConnectFault::Transport(ConnectError::Connect(_) | ConnectError::Receive(_))
                        | ConnectFault::ConnectTimeout,
                    ..
                })
                | reply::Kind::Driver(
                    cartel_pg::Error::Receive(_)
                    | cartel_pg::Error::Transmit(conn::Transmit::Io(_))
                    | cartel_pg::Error::Timeout(_)
                    | cartel_pg::Error::RequestTimeout(_)
                    | cartel_pg::Error::Connection(
                        close::Reason::Remote
                        | close::Reason::Transport
                        | close::Reason::Timeout(_),
                    ),
                ) => true,
                reply::Kind::Server(fields) => {
                    matches!(fields.code().as_str(), "57P01" | "57P02" | "57P03")
                }
                _ => false,
            };
            crate::diagnostic(
                state.diagnostics,
                format_args!("PostgreSQL request: {kind:?}"),
            );
            if !unavailable {
                return Err(Error::pg(cause));
            }
            return Ok(empty());
        }
    };
    let rows = rows.validate().map_err(Error::decode)?;
    if rows.len().get() == 0 {
        return Ok(empty());
    }
    let mut items = Vec::new();
    items
        .try_reserve_exact(rows.len().get())
        .map_err(BodyError::Allocation)
        .map_err(Error::body)?;
    for row in rows.iter() {
        items.push(Item::try_from_row(row).map_err(Error::body)?);
    }
    let count = u64::try_from(items.len())
        .map_err(BodyError::Count)
        .map_err(Error::body)?;
    let body = encode(Items { items, count }, MAX_BODY_BYTES).map_err(Error::body)?;
    Ok(Either::Left(JsonResponse {
        status: Code::OK,
        body,
    }))
}

#[sark::handler(pub)]
pub async fn fortunes<'files, P, R>(
    state: &crate::State<'files, '_, P, R>,
) -> Result<HtmlResponse, Error<'_, Infallible>>
where
    P: PgClient<'_, ID, Schema = Db>,
{
    Error::require(state.pg_configured, Upstream::Postgres)?;
    let query = state.pg.acquire().await.map_err(Error::pg)?;
    let rows = Fortune::all_rows(query)
        .await
        .map_err(Error::pg)?
        .validate()
        .map_err(Error::decode)?;
    check_limit(rows.len().get(), MAX_FORTUNES).map_err(Error::body)?;
    let mut fortunes = Vec::new();
    fortunes
        .try_reserve_exact(rows.len().get() + 1)
        .map_err(BodyError::Allocation)
        .map_err(Error::body)?;
    fortunes.extend(rows.iter().map(|row| (row.id, row.message)));
    let body = render_fortunes(fortunes).map_err(Error::body)?;
    Ok(HtmlResponse {
        status: Code::OK,
        body,
    })
}

#[sark::handler(pub)]
pub async fn item<'files, P, R>(
    request: ItemRequest,
    state: &crate::State<'files, '_, P, R>,
) -> Result<CachedResponse, Error<'_, R::Error>>
where
    P: PgClient<'_, ID, Schema = Db>,
    R: RedisClient<'_, { cache::ID }>,
{
    Error::require(state.pg_configured, Upstream::Postgres)?;
    Error::require(state.redis_configured, Upstream::Redis)?;
    let id = positive_id(request.id).map_err(Error::integer)?;
    let key = Key::item(id);
    let entry = match state
        .redis
        .acquire()
        .await
        .map_err(Error::cache)?
        .basic()
        .get(key.as_bytes())
        .await
        .map_err(Error::cache)?
    {
        Some(entry) => entry,
        None => {
            let token = state.cache_tokens.issue().map_err(Error::token)?;
            let redis = state.redis.acquire().await.map_err(Error::cache)?;
            cache::reserve(redis, key.as_bytes(), &token)
                .await
                .map_err(Error::cache)?
        }
    };
    let Some(token) = cache::reserved(entry.as_ref()) else {
        return cached(entry.as_ref()).map_err(Error::body);
    };
    drop(entry);
    let body = {
        let query = state.pg.acquire().await.map_err(Error::pg)?;
        let row = ItemRow::by_id(query, id.get()).await.map_err(Error::pg)?;
        item_json(row.decode().map_err(Error::decode)?).map_err(Error::body)?
    };
    let redis = state.redis.acquire().await.map_err(Error::cache)?;
    cache::fill(redis, key.as_bytes(), &token, &body)
        .await
        .map_err(Error::cache)?;
    Ok(CachedResponse {
        status: Code::OK,
        cache: MISS,
        body,
    })
}

#[sark::handler(pub)]
pub async fn me<'files, P, R>(
    request: MeRequest,
    state: &crate::State<'files, '_, P, R>,
) -> Result<CachedResponse, Error<'_, R::Error>>
where
    P: PgClient<'_, ID, Schema = Db>,
    R: RedisClient<'_, { cache::ID }>,
{
    let id = positive_id(request.id.ok_or_else(Error::identity)?).map_err(Error::integer)?;
    Error::require(state.pg_configured, Upstream::Postgres)?;
    Error::require(state.redis_configured, Upstream::Redis)?;
    let key = Key::user(id);
    if let Some(body) = state
        .redis
        .acquire()
        .await
        .map_err(Error::cache)?
        .basic()
        .get(key.as_bytes())
        .await
        .map_err(Error::cache)?
    {
        return cached(body.as_ref()).map_err(Error::body);
    }
    let body = {
        let query = state.pg.acquire().await.map_err(Error::pg)?;
        let row = User::by_id(query, id.get()).await.map_err(Error::pg)?;
        let row = row.decode().map_err(Error::decode)?;
        encode(
            UserBody {
                id: i64::from(row.id),
                name: row.name.into(),
                email: row.email.into(),
                plan: row.plan.into(),
            },
            cache::MAX_BYTES,
        )
        .map_err(Error::body)?
    };
    state
        .redis
        .acquire()
        .await
        .map_err(Error::cache)?
        .basic()
        .set_seconds(key.as_bytes(), &body, cache::USER_TTL)
        .await
        .map_err(Error::cache)?;
    Ok(CachedResponse {
        status: Code::OK,
        cache: MISS,
        body,
    })
}

#[sark::handler(pub)]
#[max_body(16 * 1024)]
pub async fn update<'files, P, R>(
    request: UpdateRequest,
    state: &crate::State<'files, '_, P, R>,
) -> Result<NoContent, Error<'_, R::Error>>
where
    P: PgClient<'_, ID, Schema = Db>,
    R: RedisClient<'_, { cache::ID }>,
{
    Error::require(state.pg_configured, Upstream::Postgres)?;
    Error::require(state.redis_configured, Upstream::Redis)?;
    let id = positive_id(request.id).map_err(Error::integer)?;
    let name = request.body.name.as_str();
    if name.is_empty() || name.len() > 4096 {
        return Err(Error::name());
    }
    let (price, quantity) =
        update_values(request.body.price, request.body.quantity).map_err(Error::integer)?;
    let query = state.pg.acquire().await.map_err(Error::pg)?;
    let update = ItemRow::update_fields(query, id.get(), name, price, quantity);
    drop(request);
    update.await.map_err(Error::pg)?;
    let key = Key::item(id);
    state
        .redis
        .acquire()
        .await
        .map_err(Error::cache)?
        .basic()
        .del(nonempty::Slice::from_ref(&key.as_bytes()))
        .await
        .map_err(Error::cache)?;
    Ok(NoContent {
        status: Code::NO_CONTENT,
        body: b"",
    })
}

pub fn item_json(row: ItemRowView<'_>) -> Result<storage::Shared, BodyError> {
    encode(Item::try_from_row(row)?, cache::MAX_BYTES)
}

pub fn render_fortunes(mut rows: Vec<(i32, &str)>) -> Result<Vec<u8>, BodyError> {
    check_limit(rows.len(), MAX_FORTUNES)?;
    rows.try_reserve(1).map_err(BodyError::Allocation)?;
    rows.push((0, "Additional fortune added at request time."));
    let mut bound = 256usize;
    for (_, message) in &rows {
        let escaped = message.len().checked_mul(6).ok_or(BodyError::EscapeSize {
            bytes: message.len(),
        })?;
        let row = Overflow::try_add(escaped, 64).map_err(BodyError::Size)?;
        bound = Overflow::try_add(bound, row).map_err(BodyError::Size)?;
    }
    check_limit(bound, MAX_BODY_BYTES)?;
    rows.sort_unstable_by(|left, right| left.1.cmp(right.1));
    let html = tent::html!(
        r#"| <!DOCTYPE html>
html
  head
    title "Fortunes"
  body
    table
      tr
        th "id"
        th "message"
      - for row in &rows
        tr
          td (row.0)
          td (row.1)
"#
    );
    Ok(html.into_owned().into_bytes())
}

fn positive_id(value: usize) -> Result<NonZero<i32>, TryFromIntError> {
    NonZero::try_from(i32::try_from(value)?)
}

fn number(bytes: &[u8]) -> Result<i64, NumberError> {
    str::from_utf8(bytes)
        .map_err(NumberError::Utf8)?
        .parse()
        .map_err(NumberError::Parse)
}

pub fn update_values(price: i64, quantity: i64) -> Result<(i32, i32), TryFromIntError> {
    Ok((i32::try_from(price)?, i32::try_from(quantity)?))
}

fn encode(value: impl TryEncode, maximum: usize) -> Result<storage::Shared, BodyError> {
    let plan = exact::Plan::try_new(writing::Body::new(value))
        .map_err(Rejected::discard)
        .map_err(BodyError::Size)?;
    check_limit(plan.len(), maximum)?;
    plan.into_shared().map_err(BodyError::Build)
}

fn cached(bytes: &[u8]) -> Result<CachedResponse, BodyError> {
    check_limit(bytes.len(), cache::MAX_BYTES)?;
    Raw::try_new(bytes)
        .map_err(Rejected::discard)
        .map_err(BodyError::Json)?;
    let body = storage::Shared::try_copy(bytes)
        .map_err(storage::BuildError::from)
        .map_err(BodyError::Build)?;
    Ok(CachedResponse {
        status: Code::OK,
        cache: field::literal!(Value::try_bytes(b"HIT")),
        body,
    })
}

fn check_limit(actual: usize, maximum: usize) -> Result<(), BodyError> {
    if actual > maximum {
        return Err(BodyError::Limit { actual, maximum });
    }
    Ok(())
}

pub fn pg_config(
    connections: NonZero<usize>,
    waiters: NonZero<usize>,
    configured: bool,
) -> Result<config::Config, config::Error> {
    let tasks = if configured { TASKS } else { 1 };
    config::Config::new(config::Capacities {
        connections: if configured { connections.get() } else { 1 },
        inflight: tasks,
        admission_waiters: if configured { waiters.get() } else { 1 },
        requests: config::Request {
            frames: tasks,
            frame_bytes: if configured { 16 * 1024 } else { 1 },
        },
        responses: config::Response {
            items: if configured { TASKS * 256 } else { 1 },
            bytes: if configured { 4 * MAX_BODY_BYTES } else { 1 },
            frame_bytes: if configured { MAX_BODY_BYTES } else { 5 },
        },
        notifications: config::Notification {
            items: 1,
            bytes: if configured { 1024 } else { 1 },
        },
    })
}
