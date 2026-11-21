mod fortunes;

use std::{
    cell::RefCell,
    convert::Infallible,
    env,
    fs::File,
    io::BufReader,
    net::SocketAddr,
    pin::Pin,
    sync::{Arc, LazyLock},
    task::{Context, Poll},
    time::Duration,
};

use arrayvec::ArrayVec;
use axum::{
    Router,
    body::{Body, Bytes},
    extract::{Path, Query, Request},
    http::{
        HeaderMap, HeaderValue, StatusCode, Uri,
        header::{ACCEPT_ENCODING, CONTENT_ENCODING, CONTENT_TYPE},
    },
    response::{IntoResponse, Response},
    routing::{get, post},
};
use deadpool_postgres::{
    Manager, Pool,
    tokio_postgres::{Config, NoTls},
};
use http_body::{Body as HttpBody, Frame, SizeHint};
use http_body_util::BodyExt as _;
use hyper::server::conn::http1;
use hyper_util::{rt::TokioIo, service::TowerToHyperService};
use libdeflater::{CompressionLvl, Compressor};
use proa::{WebContext, WebRenderSync};
use rustls::ServerConfig;
use serde::{Deserialize, Serialize};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::{net::TcpListener, time::sleep};
use tokio_rustls::TlsAcceptor;

use crate::fortunes::{Fortune, Fortunes};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

const FORTUNE_COUNT: usize = 201;
const ADDITIONAL_FORTUNE: &str = "Additional fortune added at request time.";
const MAX_ECHO_BODY: usize = 25 * 1024 * 1024;
const DATASET_STACK_CAP: usize = 50;
const ASYNC_DB_SQL: &str = "SELECT id, name, category, price, quantity, active, tags, rating_score, \
                            rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";

const TEXT_PLAIN: HeaderValue = HeaderValue::from_static("text/plain");
const TEXT_HTML: HeaderValue = HeaderValue::from_static("text/html; charset=utf-8");
const APP_JSON: HeaderValue = HeaderValue::from_static("application/json");
const APP_OCTET: HeaderValue = HeaderValue::from_static("application/octet-stream");
const ENC_GZIP: HeaderValue = HeaderValue::from_static("gzip");

static DATASET: LazyLock<Vec<DatasetItem>> = LazyLock::new(|| {
    let path = env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
    std::fs::read_to_string(path)
        .ok()
        .and_then(|data| serde_json::from_str(&data).ok())
        .unwrap_or_default()
});

struct CompressScratch {
    json_buf: Vec<u8>,
    gz_buf: Vec<u8>,
    compressor: Compressor,
}

impl CompressScratch {
    fn new() -> Self {
        Self {
            json_buf: Vec::with_capacity(16 * 1024),
            gz_buf: vec![0u8; 16 * 1024],
            compressor: Compressor::new(
                CompressionLvl::new(1).expect("level 1 is a valid libdeflate level"),
            ),
        }
    }
}

thread_local! {
    static PG_POOL: RefCell<Option<Pool>> = const { RefCell::new(None) };
    static COMP_SCRATCH: RefCell<CompressScratch> = RefCell::new(CompressScratch::new());
}

#[derive(Deserialize)]
struct BaselineQuery {
    a: i64,
    b: i64,
}

#[derive(Deserialize)]
struct JsonQuery {
    m: Option<i64>,
}

#[derive(Deserialize)]
struct PriceQuery {
    min: Option<i32>,
    max: Option<i32>,
    limit: Option<i32>,
}

#[derive(Deserialize)]
struct Rating {
    score: i64,
    count: i64,
}

#[derive(Deserialize)]
struct DatasetItem {
    id: i64,
    name: String,
    category: String,
    price: i64,
    quantity: i64,
    active: bool,
    tags: Vec<String>,
    rating: Rating,
}

#[derive(Serialize)]
struct RatingOut {
    score: i64,
    count: i64,
}

#[derive(Serialize)]
struct ProcessedItem<'a> {
    id: i64,
    name: &'a str,
    category: &'a str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'a [String],
    rating: RatingOut,
    total: i64,
}

#[derive(Serialize)]
struct JsonResponse<'a> {
    items: &'a [ProcessedItem<'a>],
    count: usize,
}

#[derive(Serialize)]
struct DbRating {
    score: i32,
    count: i32,
}

#[derive(Serialize)]
struct DbItem<'a> {
    id: i32,
    name: &'a str,
    category: &'a str,
    price: i32,
    quantity: i32,
    active: bool,
    tags: serde_json::Value,
    rating: DbRating,
}

#[derive(Serialize)]
struct DbList<'a> {
    items: Vec<DbItem<'a>>,
    count: usize,
}

#[allow(clippy::large_enum_variant)]
enum SmallChunks {
    Inline(ArrayVec<Bytes, 8>),
    Heap(Vec<Bytes>),
}

impl SmallChunks {
    fn new() -> Self {
        Self::Inline(ArrayVec::new())
    }

    fn push(&mut self, chunk: Bytes) {
        match self {
            Self::Inline(inline) => {
                if let Err(err) = inline.try_push(chunk) {
                    let mut heap = Vec::with_capacity(16);
                    heap.extend(inline.drain(..));
                    heap.push(err.element());
                    *self = Self::Heap(heap);
                }
            }
            Self::Heap(heap) => heap.push(chunk),
        }
    }

    fn len(&self) -> usize {
        match self {
            Self::Inline(v) => v.len(),
            Self::Heap(v) => v.len(),
        }
    }

    fn take_at(&mut self, idx: usize) -> Option<Bytes> {
        match self {
            Self::Inline(v) => v.get_mut(idx).map(std::mem::take),
            Self::Heap(v) => v.get_mut(idx).map(std::mem::take),
        }
    }
}

struct EchoBody {
    chunks: SmallChunks,
    idx: usize,
    remaining: usize,
}

impl HttpBody for EchoBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let idx = self.idx;
        if let Some(chunk) = self.chunks.take_at(idx) {
            self.idx += 1;
            self.remaining -= chunk.len();
            Poll::Ready(Some(Ok(Frame::data(chunk))))
        } else {
            Poll::Ready(None)
        }
    }

    fn is_end_stream(&self) -> bool {
        self.idx >= self.chunks.len()
    }

    fn size_hint(&self) -> SizeHint {
        SizeHint::with_exact(self.remaining as u64)
    }
}

fn load_tls_config() -> Option<Arc<ServerConfig>> {
    let cert_path = env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
    let key_path = env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
    let cert_file = File::open(cert_path).ok()?;
    let key_file = File::open(key_path).ok()?;
    let certs: Vec<_> = rustls_pemfile::certs(&mut BufReader::new(cert_file))
        .collect::<Result<_, _>>()
        .ok()?;
    let key = rustls_pemfile::private_key(&mut BufReader::new(key_file)).ok()??;

    // Prefer TLS_AES_128_GCM_SHA256 over AES-256-GCM for faster bulk AES-NI throughput
    // while enforcing TLS 1.3 AEAD-only posture.
    let mut provider = rustls::crypto::aws_lc_rs::default_provider();
    provider.cipher_suites = vec![
        rustls::crypto::aws_lc_rs::cipher_suite::TLS13_AES_128_GCM_SHA256,
        rustls::crypto::aws_lc_rs::cipher_suite::TLS13_AES_256_GCM_SHA384,
        rustls::crypto::aws_lc_rs::cipher_suite::TLS13_CHACHA20_POLY1305_SHA256,
    ];
    let mut config = ServerConfig::builder_with_provider(Arc::new(provider))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .ok()?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .ok()?;
    config.ignore_client_order = true;
    config.send_half_rtt_data = true;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Some(Arc::new(config))
}

fn reuseport_listener(addr: SocketAddr) -> std::io::Result<std::net::TcpListener> {
    let sock = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    sock.set_reuse_address(true)?;
    #[cfg(unix)]
    sock.set_reuse_port(true)?;
    sock.set_nonblocking(true)?;
    sock.bind(&addr.into())?;
    sock.listen(65535)?;
    Ok(sock.into())
}

fn serve_tls(listener: TcpListener, acceptor: TlsAcceptor, app: Router) {
    tokio::spawn(async move {
        let mut h1 = http1::Builder::new();
        h1.keep_alive(true).pipeline_flush(true);
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            let _ = stream.set_nodelay(true);
            let acceptor = acceptor.clone();
            let service = TowerToHyperService::new(app.clone());
            let h1 = h1.clone();
            tokio::spawn(async move {
                let Ok(tls_stream) = acceptor.accept(stream).await else {
                    return;
                };
                let _ = h1
                    .serve_connection(TokioIo::new(tls_stream), service)
                    .await;
            });
        }
    });
}

async fn serve_plain(listener: TcpListener, app: Router) -> std::io::Result<()> {
    let mut h1 = http1::Builder::new();
    h1.keep_alive(true).pipeline_flush(true);
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        let _ = stream.set_nodelay(true);
        let service = TowerToHyperService::new(app.clone());
        let h1 = h1.clone();
        tokio::spawn(async move {
            let _ = h1.serve_connection(TokioIo::new(stream), service).await;
        });
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let workers = std::thread::available_parallelism().map_or(1, |n| n.get());
    let (db_config, per_worker) = match env::var("DATABASE_URL") {
        Ok(url) => {
            let max_connections: usize = match env::var("DATABASE_MAX_CONN") {
                Ok(limit) => limit.parse()?,
                Err(env::VarError::NotPresent) => 256,
                Err(error) => return Err(error.into()),
            };
            (Some(url.parse::<Config>()?), (max_connections / workers).max(1))
        }
        Err(env::VarError::NotPresent) => (None, 0),
        Err(error) => return Err(error.into()),
    };

    LazyLock::force(&DATASET);
    let tls_config = load_tls_config();
    let http_addr: SocketAddr = "0.0.0.0:8080".parse()?;
    let tls_addr: SocketAddr = "0.0.0.0:8081".parse()?;

    let mut handles = Vec::with_capacity(workers);
    for _ in 0..workers {
        let db_config = db_config.clone();
        let tls_config = tls_config.clone();
        let std_http = reuseport_listener(http_addr)?;
        let std_tls = tls_config
            .as_ref()
            .map(|_| reuseport_listener(tls_addr))
            .transpose()?;

        handles.push(std::thread::spawn(move || -> std::io::Result<()> {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            rt.block_on(async move {
                if let Some(config) = db_config {
                    let pool = Pool::builder(Manager::new(config, NoTls))
                        .max_size(per_worker)
                        .build()
                        .expect("failed to build deadpool-postgres pool");
                    PG_POOL.with(|slot| *slot.borrow_mut() = Some(pool));
                }

                if let (Some(tls_cfg), Some(std_tls)) = (tls_config, std_tls) {
                    let tls_app = Router::new()
                        .route("/json/{count}", get(json_items_plain))
                        .route("/echo", post(echo_body));
                    serve_tls(
                        TcpListener::from_std(std_tls)?,
                        TlsAcceptor::from(tls_cfg),
                        tls_app,
                    );
                }

                let app = Router::new()
                    .route("/baseline11", get(baseline_get).post(baseline_post))
                    .route("/pipeline", get(pipeline))
                    .route("/delay/{ms}", get(delay))
                    .route("/json/{count}", get(json_items_comp))
                    .route("/echo", post(echo_body))
                    .route("/async-db", get(async_db))
                    .route("/fortunes", get(fortunes));

                serve_plain(TcpListener::from_std(std_http)?, app).await
            })
        }));
    }

    for handle in handles {
        handle.join().expect("worker thread panicked")?;
    }
    Ok(())
}

fn parse_baseline_query(uri: &Uri) -> Result<BaselineQuery, StatusCode> {
    let query = uri.query().ok_or(StatusCode::BAD_REQUEST)?;
    if !query.as_bytes().iter().any(|&b| b == b'%' || b == b'+') {
        let mut a = None;
        let mut b = None;
        for part in query.split('&') {
            if let Some(val) = part.strip_prefix("a=") {
                a = Some(val.parse::<i64>().map_err(|_| StatusCode::BAD_REQUEST)?);
            } else if let Some(val) = part.strip_prefix("b=") {
                b = Some(val.parse::<i64>().map_err(|_| StatusCode::BAD_REQUEST)?);
            }
        }
        return match (a, b) {
            (Some(a), Some(b)) => Ok(BaselineQuery { a, b }),
            _ => Err(StatusCode::BAD_REQUEST),
        };
    }
    Query::<BaselineQuery>::try_from_uri(uri)
        .map(|Query(q)| q)
        .map_err(|_| StatusCode::BAD_REQUEST)
}

fn parse_multiplier(uri: &Uri) -> i64 {
    let Some(query) = uri.query() else {
        return 1;
    };
    if !query.as_bytes().iter().any(|&b| b == b'%' || b == b'+') {
        for part in query.split('&') {
            if let Some(val) = part.strip_prefix("m=") {
                return val.parse::<i64>().unwrap_or(1);
            }
        }
        return 1;
    }
    Query::<JsonQuery>::try_from_uri(uri)
        .ok()
        .and_then(|Query(q)| q.m)
        .unwrap_or(1)
}

async fn pipeline() -> impl IntoResponse {
    ([(CONTENT_TYPE, TEXT_PLAIN)], Bytes::from_static(b"ok"))
}

async fn baseline_get(uri: Uri) -> Result<impl IntoResponse, StatusCode> {
    let query = parse_baseline_query(&uri)?;
    baseline_response(query, 0)
}

async fn baseline_post(uri: Uri, body: Bytes) -> Result<impl IntoResponse, StatusCode> {
    let query = parse_baseline_query(&uri)?;
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
        [(CONTENT_TYPE, TEXT_PLAIN)],
        Bytes::copy_from_slice(buffer.format(value).as_bytes()),
    )
}

async fn delay(Path(milliseconds): Path<u64>) -> impl IntoResponse {
    if milliseconds != 0 {
        sleep(Duration::from_millis(milliseconds)).await;
    }
    text_number(milliseconds)
}

async fn echo_body(req: Request) -> Result<Response, StatusCode> {
    let mut body = req.into_body();
    let mut chunks = SmallChunks::new();
    let mut total = 0usize;

    while let Some(frame_res) = body.frame().await {
        let frame = frame_res.map_err(|_| StatusCode::BAD_REQUEST)?;
        if let Ok(data) = frame.into_data()
            && !data.is_empty()
        {
            total = total
                .checked_add(data.len())
                .ok_or(StatusCode::PAYLOAD_TOO_LARGE)?;
            if total > MAX_ECHO_BODY {
                return Err(StatusCode::PAYLOAD_TOO_LARGE);
            }
            chunks.push(data);
        }
    }

    match chunks.len() {
        0 => Ok(([(CONTENT_TYPE, APP_OCTET)], Bytes::new()).into_response()),
        1 => {
            let single = chunks.take_at(0).unwrap_or_default();
            Ok(([(CONTENT_TYPE, APP_OCTET)], single).into_response())
        }
        _ => Ok((
            [(CONTENT_TYPE, APP_OCTET)],
            Body::new(EchoBody {
                chunks,
                idx: 0,
                remaining: total,
            }),
        )
            .into_response()),
    }
}

fn write_dataset_json(out: &mut Vec<u8>, count: usize, multiplier: i64) -> Result<(), StatusCode> {
    let dataset = DATASET.as_slice();
    let count = count.min(dataset.len());
    if count <= DATASET_STACK_CAP {
        let mut items = ArrayVec::<ProcessedItem<'static>, DATASET_STACK_CAP>::new();
        for item in &dataset[..count] {
            items.push(ProcessedItem {
                id: item.id,
                name: &item.name,
                category: &item.category,
                price: item.price,
                quantity: item.quantity,
                active: item.active,
                tags: &item.tags,
                rating: RatingOut {
                    score: item.rating.score,
                    count: item.rating.count,
                },
                total: item.price * item.quantity * multiplier,
            });
        }
        sonic_rs::to_writer(out, &JsonResponse { items: &items, count })
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    } else {
        let items: Vec<_> = dataset[..count]
            .iter()
            .map(|item| ProcessedItem {
                id: item.id,
                name: &item.name,
                category: &item.category,
                price: item.price,
                quantity: item.quantity,
                active: item.active,
                tags: &item.tags,
                rating: RatingOut {
                    score: item.rating.score,
                    count: item.rating.count,
                },
                total: item.price * item.quantity * multiplier,
            })
            .collect();
        sonic_rs::to_writer(out, &JsonResponse { items: &items, count })
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }
    Ok(())
}

async fn json_items_plain(
    Path(count): Path<usize>,
    uri: Uri,
) -> Result<impl IntoResponse, StatusCode> {
    let multiplier = parse_multiplier(&uri);
    let mut out = Vec::with_capacity(count.min(DATASET.len()) * 180 + 32);
    write_dataset_json(&mut out, count, multiplier)?;
    Ok(([(CONTENT_TYPE, APP_JSON)], out))
}

async fn json_items_comp(
    headers: HeaderMap,
    Path(count): Path<usize>,
    uri: Uri,
) -> Result<Response, StatusCode> {
    let multiplier = parse_multiplier(&uri);
    let accepts_gzip = headers
        .get(ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.contains("gzip"));

    COMP_SCRATCH.with(|cell| {
        let mut scratch = cell.borrow_mut();
        scratch.json_buf.clear();
        write_dataset_json(&mut scratch.json_buf, count, multiplier)?;

        if accepts_gzip {
            let raw_len = scratch.json_buf.len();
            let bound = scratch.compressor.gzip_compress_bound(raw_len);
            if scratch.gz_buf.len() < bound {
                scratch.gz_buf.resize(bound, 0);
            }
            let CompressScratch {
                json_buf,
                gz_buf,
                compressor,
            } = &mut *scratch;
            let n = compressor
                .gzip_compress(json_buf, gz_buf)
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            let body = Bytes::copy_from_slice(&gz_buf[..n]);
            Ok((
                [(CONTENT_TYPE, APP_JSON), (CONTENT_ENCODING, ENC_GZIP)],
                body,
            )
                .into_response())
        } else {
            let body = Bytes::copy_from_slice(&scratch.json_buf);
            Ok(([(CONTENT_TYPE, APP_JSON)], body).into_response())
        }
    })
}

fn worker_pool() -> Result<Pool, StatusCode> {
    PG_POOL.with(|slot| slot.borrow().clone().ok_or(StatusCode::SERVICE_UNAVAILABLE))
}

async fn async_db(Query(query): Query<PriceQuery>) -> Result<impl IntoResponse, StatusCode> {
    let pool = worker_pool()?;
    let min = query.min.unwrap_or(10);
    let max = query.max.unwrap_or(50);
    let limit = i64::from(query.limit.unwrap_or(50).clamp(1, 50));

    let rows = {
        let client = pool.get().await.map_err(database_error)?;
        let statement = client
            .prepare_cached(ASYNC_DB_SQL)
            .await
            .map_err(database_error)?;
        client
            .query(&statement, &[&min, &max, &limit])
            .await
            .map_err(database_error)?
    };

    let items: Vec<_> = rows
        .iter()
        .map(|row| DbItem {
            id: row.get(0),
            name: row.get(1),
            category: row.get(2),
            price: row.get(3),
            quantity: row.get(4),
            active: row.get(5),
            tags: row.get(6),
            rating: DbRating {
                score: row.get(7),
                count: row.get(8),
            },
        })
        .collect();
    let mut body = Vec::with_capacity(items.len() * 200 + 32);
    sonic_rs::to_writer(
        &mut body,
        &DbList {
            count: items.len(),
            items,
        },
    )
    .map_err(database_error)?;
    Ok(([(CONTENT_TYPE, APP_JSON)], body))
}

async fn fortunes() -> Result<impl IntoResponse, StatusCode> {
    let pool = worker_pool()?;
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
    Ok(([(CONTENT_TYPE, TEXT_HTML)], context.into_output()))
}

fn database_error(error: impl std::fmt::Display) -> StatusCode {
    eprintln!("could not load database rows: {error}");
    StatusCode::INTERNAL_SERVER_ERROR
}
