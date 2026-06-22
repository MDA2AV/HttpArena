use std::io;
use std::marker::PhantomData;
use std::net::{SocketAddr, ToSocketAddrs};
use std::time::Duration;

use cartel_pg::{Config, PgHolding};
use cartel_redis::Ops;
use dope::launcher::{self, Launcher};
use dope::manifold::connector::Connector;
use dope::manifold::connector::source::Static;
use dope::manifold::env::Bundle;
use dope::manifold::listener::{Listener, config};
use dope::runtime::profile::Production;
use dope::transport::Tcp;
use dope::wire::Identity;
use dope::{DriverCfg, DriverConfig, Executor};
use dope_extra::Trigger;
use http::StatusCode;
use httparena_sark::boot::Boot;
use httparena_sark::cache::ItemCache;
use httparena_sark::dataset::DATASET;
use httparena_sark::model::{Db, Fortune, ItemRow};
use o3::buffer::{Owned, Shared};
use sark::date::{DateHost, Updater};
use sark::fs::ServeDir;
use sark::json::{Encode, Json, JsonDecode, JsonEncode};
use sark::request::BodyLen;
use sark::timer::TimerHost;
use sark::{Application, ServerCfg};
use sark_core::http::Response;
use sark_core::http::LocalFrameBytes;
use sark_core::http::compress::Gzip;

type Env = Bundle<Tcp, Identity, Production>;
type PgClient<'d> = PgHolding<'d, Db, Static<Tcp>, Env>;
type PgConnector = Connector<0, cartel_pg::Session<Db>, Static<Tcp>, Env>;
type RedisConnector = Connector<4, cartel_redis::Session, Static<Tcp>, Env>;
type RedisClient<'d> = dope::fiber::Holding<'d, RedisConnector>;

#[derive(Clone)]
struct AppState<'d> {
    pg: PgClient<'d>,
    redis: Option<RedisClient<'d>>,
    cache: &'static ItemCache,
    serve: &'static ServeDir,
}

struct CacheKey(Owned);

impl CacheKey {
    fn item(id: i32) -> Self {
        let mut key = Owned::with_capacity(16);
        key.extend_from_slice(b"item:");
        Encode::extend_u64(&mut key, id as u64);
        Self(key)
    }

    fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

fn parse_body_u64(s: &[u8]) -> u64 {
    std::str::from_utf8(s)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

fn u64_owned(n: u64) -> Owned {
    let mut body = Owned::with_capacity(20);
    Encode::extend_u64(&mut body, n);
    body
}

fn accepts_gzip(accept_encoding: &[u8]) -> bool {
    accept_encoding.split(|&b| b == b',').any(|part| {
        let part = part.trim_ascii();
        let coding = part.split(|&b| b == b';').next().unwrap_or(b"").trim_ascii();
        coding.eq_ignore_ascii_case(b"gzip")
    })
}

fn respond_json<T: JsonEncode>(value: T, accept_encoding: &[u8]) -> Response {
    let body = value.encode_json();
    let mut response = Response::ok();
    response.content_type("application/json");
    if accepts_gzip(accept_encoding) {
        let compressed = Gzip::with_thread_local(|g| Shared::from(g.encode(&body).to_vec()));
        response.append_wire_header_static("content-encoding", "gzip");
        response.append_wire_header_static("vary", "accept-encoding");
        response.set_body(compressed);
    } else {
        response.set_body(body);
    }
    response
}

fn local_owned(bytes: &[u8]) -> LocalFrameBytes {
    LocalFrameBytes::from_shared(Shared::copy_from_slice(bytes))
}

#[sark_gen::json(ordered)]
struct Rating {
    score: u64,
    count: u64,
}

#[sark_gen::json(ordered)]
struct JsonItem {
    id: u64,
    name: LocalFrameBytes,
    category: LocalFrameBytes,
    price: u64,
    quantity: u64,
    active: bool,
    #[field(seq)]
    tags: Vec<LocalFrameBytes>,
    #[field(nested)]
    rating: Rating,
    total: u64,
}

#[sark_gen::json(ordered)]
struct ItemsResponse {
    #[field(seq, nested)]
    items: Vec<JsonItem>,
    count: u64,
}

#[sark_gen::json(ordered)]
struct DbItem {
    id: u64,
    name: LocalFrameBytes,
    category: LocalFrameBytes,
    price: u64,
    quantity: u64,
    active: bool,
    #[field(raw)]
    tags: LocalFrameBytes,
    #[field(nested)]
    rating: Rating,
}

#[sark_gen::json(ordered)]
struct DbResponse {
    #[field(seq, nested)]
    items: Vec<DbItem>,
    count: u64,
}

#[sark_gen::json(ordered)]
struct CrudListResponse {
    #[field(seq, nested)]
    items: Vec<DbItem>,
    total: u64,
    page: u64,
    limit: u64,
}

#[sark_gen::json(ordered)]
struct CreatedItem {
    id: u64,
    name: LocalFrameBytes,
    category: LocalFrameBytes,
    price: u64,
    quantity: u64,
}

#[sark_gen::json(ordered)]
struct UpdatedItem {
    id: u64,
    name: LocalFrameBytes,
    price: u64,
    quantity: u64,
}

#[sark_gen::json(ordered)]
struct IdResponse {
    id: u64,
}

#[sark_gen::json]
struct CreateBody {
    id: u64,
    name: LocalFrameBytes,
    category: LocalFrameBytes,
    price: u64,
    quantity: u64,
}

#[sark_gen::json]
struct UpdateBody {
    name: LocalFrameBytes,
    price: u64,
    quantity: u64,
}

fn db_item(row: &ItemRow) -> DbItem {
    DbItem {
        id: row.id as u64,
        name: local_owned(row.name.as_bytes()),
        category: local_owned(row.category.as_bytes()),
        price: row.price as u64,
        quantity: row.quantity as u64,
        active: row.active,
        tags: local_owned(row.tags.as_str().as_bytes()),
        rating: Rating {
            score: row.rating_score as u64,
            count: row.rating_count as u64,
        },
    }
}

#[sark_gen::response(raw)]
#[header("content-type", "text/plain")]
struct BaselineResponse {
    status: StatusCode,
    body: Owned,
}

#[sark_gen::request(ordered)]
struct BaselineGet {
    #[query("a", default = "0")]
    a: u64,
    #[query("b", default = "0")]
    b: u64,
}

#[sark_gen::handler]
fn baseline_get(req: BaselineGet, _state: &AppState<'_>) -> BaselineResponse {
    BaselineResponse {
        status: StatusCode::OK,
        body: u64_owned(req.a.wrapping_add(req.b)),
    }
}

#[sark_gen::request(ordered)]
struct BaselinePost {
    #[query("a", default = "0")]
    a: u64,
    #[query("b", default = "0")]
    b: u64,
    #[raw_body]
    payload: LocalFrameBytes,
}

#[sark_gen::handler]
fn baseline_post(req: BaselinePost, _state: &AppState<'_>) -> BaselineResponse {
    let c = parse_body_u64(req.payload.as_bytes());
    BaselineResponse {
        status: StatusCode::OK,
        body: u64_owned(req.a.wrapping_add(req.b).wrapping_add(c)),
    }
}

#[sark_gen::response(raw)]
#[header("content-type", "text/plain")]
struct PipelineResponse {
    status: StatusCode,
    body: &'static [u8],
}

#[sark_gen::request]
struct PipelineRequest {}

#[sark_gen::handler]
#[static_response]
fn pipeline_endpoint(_req: PipelineRequest, _state: &AppState<'_>) -> PipelineResponse {
    PipelineResponse {
        status: StatusCode::OK,
        body: b"ok",
    }
}

#[sark_gen::request(ordered)]
struct JsonRequest {
    #[path("count", default = "1")]
    count: u64,
    #[query("m", default = "1")]
    m: u64,
    #[header("accept-encoding", default = "")]
    accept_encoding: LocalFrameBytes,
}

#[sark_gen::handler]
fn json_endpoint(req: JsonRequest, _state: &AppState<'_>) -> Response {
    let count = req.count.clamp(1, 50) as usize;
    let m = req.m.max(1);
    let mut items = Vec::with_capacity(count);
    for item in DATASET.iter().take(count) {
        let tags = item
            .tags
            .iter()
            .map(|t| LocalFrameBytes::from_slice(t))
            .collect();
        items.push(JsonItem {
            id: item.id as u64,
            name: LocalFrameBytes::from_slice(item.name),
            category: LocalFrameBytes::from_slice(item.category),
            price: item.price as u64,
            quantity: item.quantity as u64,
            active: item.active,
            tags,
            rating: Rating {
                score: item.rating_score as u64,
                count: item.rating_count as u64,
            },
            total: (item.price as u64) * (item.quantity as u64) * m,
        });
    }
    respond_json(
        ItemsResponse {
            items,
            count: count as u64,
        },
        req.accept_encoding.as_bytes(),
    )
}

#[sark_gen::request(ordered)]
struct AsyncDbRequest {
    #[query("min", default = "10")]
    min: u64,
    #[query("max", default = "50")]
    max: u64,
    #[query("limit", default = "50")]
    limit: u64,
}

#[sark_gen::handler]
async fn async_db(req: AsyncDbRequest, state: &AppState<'_>) -> Response {
    let min = req.min.clamp(1, 1_000_000) as i32;
    let max = req.max.clamp(1, 1_000_000) as i32;
    let limit = req.limit.clamp(1, 50) as i64;
    let rows = match ItemRow::range(&state.pg, min, max, limit).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("async_db range err: {e:?}");
            Vec::new()
        }
    };
    let count = rows.len() as u64;
    let items = rows.iter().map(db_item).collect();
    Json::ok(DbResponse { items, count })
}

#[sark_gen::request]
struct FortunesRequest {}

#[sark_gen::handler]
async fn fortunes(_req: FortunesRequest, state: &AppState<'_>) -> Response {
    let mut rows = match Fortune::all_rows(&state.pg).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("fortunes all_rows err: {e:?}");
            Vec::new()
        }
    };
    rows.push(Fortune {
        id: 0,
        message: cartel_pg::Text::from_static("Additional fortune added at request time."),
    });
    rows.sort_unstable_by(|a, b| a.message.as_str().cmp(b.message.as_str()));
    let table = tent::html_body!(
        "table\n  tr\n    th \"id\"\n    th \"message\"\n  - for f in &rows\n    tr\n      td (f.id)\n      td (f.message.as_str())"
    );
    let rendered = table.finish();
    let mut body = Owned::with_capacity(rendered.len() + 96);
    body.extend_from_slice(b"<!DOCTYPE html><html><head><title>Fortunes</title></head><body>");
    body.extend_from_slice(rendered.as_bytes());
    body.extend_from_slice(b"</body></html>");
    let mut response = Response::ok();
    response.content_type("text/html; charset=UTF-8");
    response.set_body(body);
    response
}

#[sark_gen::request(ordered)]
struct CrudListRequest {
    #[query("category", default = "electronics")]
    category: LocalFrameBytes,
    #[query("page", default = "1")]
    page: u64,
    #[query("limit", default = "10")]
    limit: u64,
}

#[sark_gen::handler]
async fn crud_list(req: CrudListRequest, state: &AppState<'_>) -> Response {
    let category = std::str::from_utf8(req.category.as_bytes()).unwrap_or("electronics");
    let limit = req.limit.clamp(1, 50) as i64;
    let page = req.page.max(1);
    let offset = ((page - 1) as i64) * limit;
    let rows = ItemRow::by_category_paged(&state.pg, category, limit, offset)
        .await
        .unwrap_or_default();
    let total = rows.len() as u64;
    let items = rows.iter().map(db_item).collect();
    Json::ok(CrudListResponse {
        items,
        total,
        page,
        limit: limit as u64,
    })
}

#[sark_gen::request(ordered)]
struct CrudGetRequest {
    #[path("id", default = "0")]
    id: u64,
}

#[sark_gen::handler]
async fn crud_get(req: CrudGetRequest, state: &AppState<'_>) -> Response {
    let id = req.id as i32;
    if let Some(redis) = &state.redis {
        let key = CacheKey::item(id);
        if let Ok(Some(cached)) = redis.get(key.as_bytes()).await {
            let mut body = Owned::with_capacity(cached.as_ref().len());
            body.extend_from_slice(cached.as_ref());
            let mut response = Response::ok();
            response.content_type("application/json");
            response.append_wire_header_static("x-cache", "HIT");
            response.set_body(body);
            return response;
        }
        let fetched = ItemRow::by_id(&state.pg, id).await.ok().flatten();
        return match fetched {
            Some(row) => {
                let body = db_item(&row).encode_json();
                let _ = redis
                    .set_ex(key.as_bytes(), &body, Duration::from_millis(200))
                    .await;
                let mut response = Response::ok();
                response.content_type("application/json");
                response.append_wire_header_static("x-cache", "MISS");
                response.set_body(body);
                response
            }
            None => {
                let mut response = Response::not_found();
                response.append_wire_header_static("x-cache", "MISS");
                response
            }
        };
    }
    let (row, cache_status) = if let Some(cached) = state.cache.get(id) {
        (Some(cached), "HIT")
    } else {
        let fetched = ItemRow::by_id(&state.pg, id).await.ok().flatten();
        if let Some(ref r) = fetched {
            state.cache.insert(id, r.clone());
        }
        (fetched, "MISS")
    };
    match row {
        Some(r) => {
            let mut response = Json::ok(db_item(&r));
            response.append_wire_header_static("x-cache", cache_status);
            response
        }
        None => {
            let mut response = Response::not_found();
            response.append_wire_header_static("x-cache", cache_status);
            response
        }
    }
}

#[sark_gen::request(ordered)]
struct CrudCreateRequest {
    #[raw_body]
    payload: LocalFrameBytes,
}

#[sark_gen::handler]
async fn crud_create(req: CrudCreateRequest, state: &AppState<'_>) -> Response {
    let (id, name, category, price, quantity) = match CreateBody::decode_json(req.payload.into_bytes())
    {
        Ok(b) => (
            b.id as i32,
            b.name,
            b.category,
            b.price as i32,
            b.quantity as i32,
        ),
        Err(_) => (
            0,
            LocalFrameBytes::from_slice(b""),
            LocalFrameBytes::from_slice(b""),
            0,
            0,
        ),
    };
    let _ = ItemRow::create(
        &state.pg,
        id,
        std::str::from_utf8(name.as_bytes()).unwrap_or("").to_owned(),
        std::str::from_utf8(category.as_bytes())
            .unwrap_or("")
            .to_owned(),
        price,
        quantity,
        true,
        cartel_pg::Jsonb::from_static_json("[]"),
        0,
        0,
    )
    .await;
    Json::status(
        StatusCode::CREATED,
        CreatedItem {
            id: id as u64,
            name,
            category,
            price: price as u64,
            quantity: quantity as u64,
        },
    )
}

#[sark_gen::request(ordered)]
struct CrudUpdateRequest {
    #[path("id", default = "0")]
    id: u64,
    #[raw_body]
    payload: LocalFrameBytes,
}

#[sark_gen::handler]
async fn crud_update(req: CrudUpdateRequest, state: &AppState<'_>) -> Response {
    let id = req.id as i32;
    let (name, price, quantity) = match UpdateBody::decode_json(req.payload.into_bytes()) {
        Ok(b) => (b.name, b.price as i32, b.quantity as i32),
        Err(_) => (LocalFrameBytes::from_slice(b""), 0, 0),
    };
    let _ = ItemRow::update_fields(
        &state.pg,
        id,
        std::str::from_utf8(name.as_bytes()).unwrap_or("").to_owned(),
        price,
        quantity,
    )
    .await;
    if let Some(redis) = &state.redis {
        let key = CacheKey::item(id);
        let _ = redis.del(&[key.as_bytes()]).await;
    }
    state.cache.invalidate(id);
    Json::ok(UpdatedItem {
        id: id as u64,
        name,
        price: price as u64,
        quantity: quantity as u64,
    })
}

#[sark_gen::response(raw)]
#[header("content-type", "text/plain")]
struct UploadResponse {
    status: StatusCode,
    body: Owned,
}

#[sark_gen::request(ordered)]
struct UploadRequest {
    #[stream_body]
    payload: BodyLen,
}

#[sark_gen::handler]
#[max_body(32 * 1024 * 1024)]
fn upload_endpoint(req: UploadRequest, _state: &AppState<'_>) -> UploadResponse {
    UploadResponse {
        status: StatusCode::OK,
        body: u64_owned(req.payload.len() as u64),
    }
}

#[sark_gen::request(ordered)]
struct StaticFileRequest {
    #[path("file", default = "")]
    file: LocalFrameBytes,
    #[header("accept-encoding", default = "")]
    accept_encoding: LocalFrameBytes,
}

#[sark_gen::handler]
fn static_endpoint(req: StaticFileRequest, state: &AppState<'_>) -> Response {
    state
        .serve
        .serve(req.file.as_bytes(), req.accept_encoding.as_bytes())
}

#[sark_gen::request(ordered)]
struct ApiMeRequest {
    #[header("x-user-id", default = "0")]
    user_id: LocalFrameBytes,
}

#[sark_gen::handler]
fn api_me(req: ApiMeRequest, _state: &AppState<'_>) -> Response {
    let uid = std::str::from_utf8(req.user_id.as_bytes())
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0);
    Json::ok(IdResponse { id: uid })
}

#[sark_gen::response(raw)]
struct NoContentResponse {
    status: StatusCode,
    body: &'static [u8],
}

#[sark_gen::request(ordered)]
struct ApiPostRequest {
    #[path("id", default = "0")]
    id: u64,
    #[raw_body]
    payload: LocalFrameBytes,
}

#[sark_gen::handler]
async fn api_items_post(req: ApiPostRequest, state: &AppState<'_>) -> NoContentResponse {
    let id = req.id as i32;
    let _ = req.payload.as_bytes();
    if let Some(redis) = &state.redis {
        let key = CacheKey::item(id);
        let _ = redis.del(&[key.as_bytes()]).await;
    }
    state.cache.invalidate(id);
    NoContentResponse {
        status: StatusCode::NO_CONTENT,
        body: b"",
    }
}

sark_gen::define_route! {
    HttpArena: AppState<'d> => {
        GET "/baseline11" => baseline_get,
        POST "/baseline11" => baseline_post,
        GET "/baseline2" => baseline_get,
        POST "/baseline2" => baseline_post,
        GET "/pipeline" => pipeline_endpoint,
        GET "/json/:count" => json_endpoint,
        GET "/async-db" => async async_db,
        GET "/fortunes" => async fortunes,
        GET "/crud/items" => async crud_list,
        GET "/crud/items/:id" => async crud_get,
        POST "/crud/items" => async crud_create,
        PUT "/crud/items/:id" => async crud_update,
        POST "/upload" => upload_endpoint,
        GET "/static/:file" => static_endpoint,
        GET "/public/baseline" => baseline_get,
        GET "/public/json/:count" => json_endpoint,
        GET "/api/items/:id" => async crud_get,
        POST "/api/items/:id" => async api_items_post,
        GET "/api/me" => api_me,
    }
}

#[pin_project::pin_project]
#[derive(dope_gen::Dispatcher)]
struct Dispatcher<'d, P>
where
    P: Application<Conn = sark::dispatch::conn_state::ConnState, Wire = dope::wire::Identity>
        + DateHost
        + TimerHost<'d>,
{
    #[pin]
    #[manifold(optional)]
    http: Option<Listener<1, P, Env>>,
    #[pin]
    #[manifold]
    date: Updater<2>,
    #[pin]
    #[manifold]
    pg: PgConnector,
    #[pin]
    #[manifold]
    timer: dope::manifold::timer::Timer<{ sark::timer::SARK_TIMER_ID }>,
    #[pin]
    #[manifold(optional)]
    redis: Option<RedisConnector>,
    _ph: PhantomData<&'d ()>,
}

struct PgArgs {
    addr: SocketAddr,
    config: Config,
    pool: usize,
    redis_addr: Option<SocketAddr>,
    serve: &'static ServeDir,
}

fn run_thread(
    pg: PgArgs,
    cfg: ServerCfg,
    ctx: launcher::Ctx,
    shutdown: Option<&Trigger>,
) -> io::Result<()> {
    let driver_cfg =
        DriverCfg::for_tcp_profile::<Production>(cfg.max_conn).with_cpu_id(Some(ctx.cpu));
    let mut exec = Executor::new(driver_cfg)?;

    let pg_conn = {
        let driver = exec.driver_mut();
        if let Some(trigger) = shutdown {
            trigger.register(driver);
        }
        Connector::new(
            cartel_pg::Session::new(pg.config),
            Static::<Tcp>::new(vec![pg.addr], Duration::from_millis(500)),
            pg.pool,
            driver,
        )
    };
    let redis_conn = pg.redis_addr.map(|addr| {
        let driver = exec.driver_mut();
        Connector::new(
            cartel_redis::Session::new(),
            Static::<Tcp>::new(vec![addr], cartel_redis::DEFAULT_BACKOFF),
            2,
            driver,
        )
    });
    let mut app = core::pin::pin!(Dispatcher::<_> {
        http: None::<Listener<1, _, Env>>,
        date: Updater::<2>::new(),
        pg: pg_conn,
        timer: dope::manifold::timer::Timer::new(),
        redis: redis_conn,
        _ph: PhantomData,
    });
    let client = app.as_mut().pg_handle();
    let redis_client = app.as_mut().redis_handle();
    let timer_borrow = app.as_mut().timer_handle();

    let cache: &'static ItemCache = Box::leak(Box::new(ItemCache::new(Duration::from_millis(200))));
    let app_state: &AppState<'_> = Box::leak(Box::new(AppState {
        pg: client,
        redis: redis_client,
        cache,
        serve: pg.serve,
    }));
    let server = http_arena::new(app_state);
    let listener_cfg = config::Config::<Tcp> {
        max_conn: cfg.max_conn,
        bind: cfg.bind,
        backlog: cfg.backlog,
        stream_opts: dope::transport::config::tcp::StreamOpts::default(),
        listener_opts: dope::transport::config::tcp::ListenerOpts {
            reuseport: dope::transport::config::SocketToggle::Enabled,
            ..Default::default()
        },
    };
    let mut http = {
        let driver = exec.driver_mut();
        Listener::<1, _, Env>::open_in(server, listener_cfg, driver)?
    };
    let stamp = {
        let handler = http.handler_mut();
        if !handler.is_timer_bound() {
            handler.bind_timer(timer_borrow);
        }
        std::ptr::NonNull::from(handler.date_stamp())
    };
    let mut init = app.as_mut().project();
    init.date.as_mut().get_mut().bind(stamp);
    init.http.set(Some(http));
    exec.run(app.as_mut())
}

fn main() -> io::Result<()> {
    let boot = Boot::from_env(8080);
    let core_count = boot.cpus.len();
    let pg_pool: usize = (std::env::var("DATABASE_MAX_CONN")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(256usize)
        .saturating_sub(16)
        / core_count)
        .max(1);

    let (pg_user, pg_password, pg_database, pg_addr) = parse_database_url();
    let redis_addr = parse_redis_url();
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    let serve: &'static ServeDir = Box::leak(Box::new(
        ServeDir::new(&static_dir)
            .precompressed_br()
            .precompressed_gzip(),
    ));

    let cfg = ServerCfg {
        bind: boot.bind,
        max_conn: boot.max_conn,
        backlog: boot.max_conn as i32,
    };

    Launcher::new(boot.cpus).run(move |ctx| {
        let pg = PgArgs {
            addr: pg_addr,
            config: Config::new(pg_user.clone(), pg_password.clone(), pg_database.clone()),
            pool: pg_pool,
            redis_addr,
            serve,
        };
        run_thread(pg, cfg.clone(), ctx, None)
    })
}

fn parse_redis_url() -> Option<SocketAddr> {
    let url = std::env::var("REDIS_URL").ok()?;
    let hostport = url.strip_prefix("redis://").unwrap_or(&url);
    let hostport = hostport.split('/').next().unwrap_or(hostport);
    hostport.to_socket_addrs().ok()?.next()
}

fn parse_database_url() -> (String, String, String, SocketAddr) {
    let url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://bench:bench@localhost:5432/benchmark".into());
    let rest = url
        .strip_prefix("postgres://")
        .or_else(|| url.strip_prefix("postgresql://"))
        .expect("DATABASE_URL must start with postgres://");
    let (creds, hostpart) = rest.split_once('@').expect("DATABASE_URL missing @");
    let (user, password) = creds.split_once(':').unwrap_or((creds, ""));
    let (hostport, db) = hostpart.split_once('/').unwrap_or((hostpart, "benchmark"));
    let addr: SocketAddr = hostport
        .to_socket_addrs()
        .expect("resolve DATABASE_URL host:port")
        .next()
        .expect("DATABASE_URL host:port resolved to no address");
    (user.into(), password.into(), db.into(), addr)
}
