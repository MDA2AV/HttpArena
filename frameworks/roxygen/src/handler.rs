use std::fs;
use std::future::ready;
use std::io;
use std::path::Path;
use std::path::PathBuf;
use std::rc::Rc;
use std::task::Context;
use std::task::Poll;

use bytes::Bytes;
use roxygen_core::buf_queue::BufQueue;
use roxygen_core::error::HttpError;
use roxygen_core::error::HttpErrorCode;
use roxygen_core::events::HttpBodyEvent;
use roxygen_core::events::HttpBodyEventKind;
use roxygen_core::events::HttpHeaderEvent;
use roxygen_core::handler::HandlerSessionContext;
use roxygen_core::handler::HttpHandler;
use roxygen_core::handler::LocalHandlerFuture;
use roxygen_core::headers::HttpHeaderCode;
use roxygen_core::http::HttpMethod;
use roxygen_core::message::HttpMessage;
use roxygen_core::message::MessageTypeError;
use roxygen_core::source::HttpSource;
use roxygen_core::source::LocalSourceFuture;
use roxygen_core::source_holder::HttpSourceHolder;
use roxygen_server::experimental::StaticFiles;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Number;

#[derive(Deserialize)]
pub struct Rating {
    score: Number,
    count: Number,
}

#[derive(Deserialize)]
pub struct Item {
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
struct RatingOut<'a> {
    score: &'a Number,
    count: &'a Number,
}

#[derive(Serialize)]
struct ItemOut<'a> {
    id: i64,
    name: &'a str,
    category: &'a str,
    price: i64,
    quantity: i64,
    active: bool,
    tags: &'a [String],
    rating: RatingOut<'a>,
    total: i64,
}

#[derive(Serialize)]
struct JsonOut<'a> {
    items: Vec<ItemOut<'a>>,
    count: usize,
}

/// Process-wide state shared by every worker.
pub struct Arena {
    dataset: Vec<Item>,
    static_dir: PathBuf,
    heads: Heads,
}

impl Arena {
    pub fn load(dataset: &Path, static_dir: &Path) -> io::Result<Self> {
        let raw = fs::read(dataset)?;
        let dataset = serde_json::from_slice(&raw).map_err(io::Error::other)?;
        Ok(Self {
            dataset,
            static_dir: static_dir.to_path_buf(),
            heads: Heads::new().map_err(io::Error::other)?,
        })
    }
}

/// Response heads that each response clones, which skips the clock read of
/// `HttpMessage::new`.
struct Heads {
    /// A 200 response without headers.
    ok: Box<HttpMessage>,
    /// The whole 404 response head.
    not_found: Box<HttpMessage>,
    /// The whole `/baseline2` response head.
    baseline: Box<HttpMessage>,
}

impl Heads {
    fn new() -> Result<Self, MessageTypeError> {
        let ok = status_head(200)?;
        Ok(Self {
            not_found: with_length(status_head(404)?, 0),
            baseline: with_type(ok.clone(), b"text/plain"),
            ok,
        })
    }

    /// A copy for one worker, whose whole heads share their header entries with
    /// their clones.
    fn for_worker(&self) -> Self {
        let shared = |head: &HttpMessage| {
            let mut head = Box::new(head.clone());
            head.headers_mut().share_entries();
            head
        };
        Self {
            ok: self.ok.clone(),
            not_found: shared(&self.not_found),
            baseline: shared(&self.baseline),
        }
    }
}

fn status_head(status: u16) -> Result<Box<HttpMessage>, MessageTypeError> {
    let mut head = Box::new(HttpMessage::new());
    head.set_status_code(status)?;
    head.set_status_message(HttpMessage::default_reason(status))?;
    head.set_http_version(1, 1);
    Ok(head)
}

/// Adds `Content-Type` to `head`. A typed body is sent without `Content-Length`,
/// since END_STREAM ends an HTTP/2 body.
fn with_type(mut head: Box<HttpMessage>, content_type: &[u8]) -> Box<HttpMessage> {
    head.headers_mut()
        .add(HttpHeaderCode::ContentType, content_type);
    head
}

/// Adds `Content-Length` to `head`, for a body without a type.
fn with_length(mut head: Box<HttpMessage>, length: usize) -> Box<HttpMessage> {
    head.headers_mut().add(
        HttpHeaderCode::ContentLength,
        Decimal::length(length).as_bytes(),
    );
    head
}

/// One worker's state; its static file cache and response heads belong to that worker.
struct Worker {
    arena: &'static Arena,
    files: StaticFiles,
    heads: Heads,
}

pub struct Handler {
    worker: Rc<Worker>,
}

impl Handler {
    /// One worker's handler.
    pub fn new(arena: &'static Arena) -> Self {
        Self {
            worker: Rc::new(Worker {
                arena,
                files: StaticFiles::new(&arena.static_dir).with_precompressed(true),
                heads: arena.heads.for_worker(),
            }),
        }
    }
}

impl HttpHandler for Handler {
    fn handle_request(
        &self,
        _context: HandlerSessionContext,
        mut request: HttpSourceHolder,
    ) -> LocalHandlerFuture {
        let worker = Rc::clone(&self.worker);
        Box::pin(async move {
            let mut head = request.read_header_event_unboxed().await?;
            let message = head.headers();
            let url = message.request_url().unwrap_or_default();
            let (path, query) = match url.iter().position(|&byte| byte == b'?') {
                Some(at) => (&url[..at], &url[at + 1..]),
                None => (url, &b""[..]),
            };
            let heads = &worker.heads;
            if path == b"/baseline2" {
                return baseline(heads, request, query);
            }
            if let Some(count) = path.strip_prefix(b"/json/") {
                return json(worker.arena, heads, request, count, query);
            }
            if let Some(name) = path.strip_prefix(b"/static/") {
                let accept = message
                    .headers()
                    .get_single_or_empty(HttpHeaderCode::AcceptEncoding);
                return worker.files.respond(name, accept);
            }
            if path == b"/spec" || path == b"/spec/headers" {
                let list_headers = path == b"/spec/headers";
                let method = head.headers_mut().method().map_err(internal)?;
                // Boxed so that the rarely used /spec state does not grow every request's
                // future.
                return Box::pin(spec(&worker.heads, request, head, method, list_headers)).await;
            }
            respond(request, heads.not_found.clone(), Bytes::new())
        })
    }
}

fn internal(error: impl std::fmt::Display) -> HttpError {
    HttpError::with_message(HttpErrorCode::INTERNAL_ERROR, error.to_string())
}

/// Answers with `head`, which carries the body's headers, and `body`.
///
/// The response goes into the request's holder. The request has been read up to
/// its headers, and a request body that is still unread is stopped, as dropping
/// the holder would stop it.
fn respond(
    request: HttpSourceHolder,
    head: Box<HttpMessage>,
    body: Bytes,
) -> Result<HttpSourceHolder, HttpError> {
    let length = body.len();
    let body = BufQueue::from_bytes(body, length).map_err(internal)?;
    Ok(respond_with_queue(request, head, body))
}

/// [`respond`] with a body that is already a queue.
fn respond_with_queue(
    mut request: HttpSourceHolder,
    head: Box<HttpMessage>,
    body: BufQueue,
) -> HttpSourceHolder {
    request.set_source(Box::new(Response {
        head: Some(head),
        body,
    }));
    request
}

/// A whole response in memory. It reads like `HttpFixedSource`, but its head is
/// allocated once and moves into the header event, and its body is polled in place.
struct Response {
    head: Option<Box<HttpMessage>>,
    body: BufQueue,
}

impl Response {
    fn next_body(&mut self, maximum: u32) -> HttpBodyEvent {
        let body = self.body.split_at_most(maximum as usize);
        HttpBodyEvent::body(body, self.body.is_empty())
    }
}

impl HttpSource for Response {
    fn read_header_event(&mut self) -> LocalSourceFuture<Result<HttpHeaderEvent, HttpError>> {
        let event = match self.head.take() {
            Some(head) => {
                HttpHeaderEvent::from_boxed_headers(head, self.body.is_empty()).map_err(internal)
            }
            None => Err(HttpError::with_message(
                HttpErrorCode::INVALID_STATE_TRANSITION,
                b"response header was already read",
            )),
        };
        Box::pin(ready(event))
    }

    fn read_body_event(
        &mut self,
        maximum: u32,
    ) -> LocalSourceFuture<Result<HttpBodyEvent, HttpError>> {
        Box::pin(ready(Ok(self.next_body(maximum))))
    }

    fn stop_reading(&mut self, _error: Option<HttpErrorCode>) {}

    fn polls_body_events(&self) -> bool {
        true
    }

    fn poll_body_event(
        &mut self,
        _context: &mut Context<'_>,
        maximum: u32,
    ) -> Poll<Result<HttpBodyEvent, HttpError>> {
        Poll::Ready(Ok(self.next_body(maximum)))
    }
}

/// An integer in decimal, as `to_string` writes it.
struct Decimal {
    bytes: [u8; Self::CAPACITY],
    start: usize,
}

impl Decimal {
    /// The length of the longest value, `i64::MIN` or `u64::MAX`.
    const CAPACITY: usize = 20;

    fn new(value: i64) -> Self {
        Self::with_sign(value.unsigned_abs(), value < 0)
    }

    fn length(value: usize) -> Self {
        Self::with_sign(value as u64, false)
    }

    #[inline]
    fn with_sign(mut magnitude: u64, negative: bool) -> Self {
        let mut bytes = [0; Self::CAPACITY];
        let mut start = Self::CAPACITY;
        loop {
            start -= 1;
            bytes[start] = b'0' + (magnitude % 10) as u8;
            magnitude /= 10;
            if magnitude == 0 {
                break;
            }
        }
        if negative {
            start -= 1;
            bytes[start] = b'-';
        }
        Self { bytes, start }
    }

    fn as_bytes(&self) -> &[u8] {
        &self.bytes[self.start..]
    }
}

/// The values of `names` in a query string as integers, found in one pass. A name
/// takes the value of its first `name=` pair, and is 0 if it has none or that
/// value is not an `i64`.
#[inline]
fn query_ints<const N: usize>(query: &[u8], names: [&[u8]; N]) -> [i64; N] {
    let mut values = [None; N];
    for pair in query.split(|&byte| byte == b'&') {
        let Some(at) = pair.iter().position(|&byte| byte == b'=') else {
            continue;
        };
        if let Some(index) = names.iter().position(|&name| name == &pair[..at]) {
            values[index].get_or_insert(&pair[at + 1..]);
        }
    }
    values.map(|value| value.and_then(parse_i64).unwrap_or(0))
}

/// Parses an `i64` as `str::parse` does: an optional sign, then at least one
/// ASCII digit, without overflow.
fn parse_i64(text: &[u8]) -> Option<i64> {
    let (negative, digits) = match text {
        [b'-', digits @ ..] => (true, digits),
        [b'+', digits @ ..] => (false, digits),
        digits => (false, digits),
    };
    if digits.is_empty() {
        return None;
    }
    let mut value: i64 = 0;
    for &byte in digits {
        let digit = byte.wrapping_sub(b'0');
        if digit > 9 {
            return None;
        }
        value = value.checked_mul(10)?;
        value = if negative {
            value.checked_sub(i64::from(digit))?
        } else {
            value.checked_add(i64::from(digit))?
        };
    }
    Some(value)
}

fn baseline(
    heads: &Heads,
    request: HttpSourceHolder,
    query: &[u8],
) -> Result<HttpSourceHolder, HttpError> {
    let [a, b] = query_ints(query, [b"a", b"b"]);
    let sum = Decimal::new(a.wrapping_add(b));
    let sum = sum.as_bytes();
    respond(request, heads.baseline.clone(), Bytes::copy_from_slice(sum))
}

fn json(
    arena: &Arena,
    heads: &Heads,
    request: HttpSourceHolder,
    count: &[u8],
    query: &[u8],
) -> Result<HttpSourceHolder, HttpError> {
    let Some(count) = std::str::from_utf8(count)
        .ok()
        .and_then(|count| count.parse::<usize>().ok())
    else {
        return respond(request, heads.not_found.clone(), Bytes::new());
    };
    let [m] = query_ints(query, [b"m"]);
    let items: Vec<ItemOut<'_>> = arena
        .dataset
        .iter()
        .take(count)
        .map(|item| ItemOut {
            id: item.id,
            name: &item.name,
            category: &item.category,
            price: item.price,
            quantity: item.quantity,
            active: item.active,
            tags: &item.tags,
            rating: RatingOut {
                score: &item.rating.score,
                count: &item.rating.count,
            },
            total: item.price.wrapping_mul(item.quantity).wrapping_mul(m),
        })
        .collect();
    let count = items.len();
    let body = serde_json::to_vec(&JsonOut { items, count }).map_err(internal)?;
    let head = with_type(heads.ok.clone(), b"application/json");
    respond(request, head, Bytes::from(body))
}

/// The largest request body `/spec` reads.
const MAX_SPEC_BODY: usize = 16 << 20;

/// `/spec` and `/spec/headers`, the routes the protocol-compliance suites use.
/// They read the request body through the same holder as every other route.
async fn spec(
    heads: &Heads,
    mut request: HttpSourceHolder,
    head: HttpHeaderEvent,
    method: Option<HttpMethod>,
    list_headers: bool,
) -> Result<HttpSourceHolder, HttpError> {
    let keep_body = !list_headers && method == Some(HttpMethod::Post);
    let body = if head.eom() {
        BufQueue::new(0)
    } else {
        read_body(&mut request, keep_body).await?
    };
    let text = || with_type(heads.ok.clone(), b"text/plain");

    if list_headers {
        let listing: Vec<u8> = head
            .headers()
            .headers()
            .iter()
            .flat_map(|(_, name, value)| [name, &b": "[..], value, &b"\n"[..]].concat())
            .collect();
        return respond(request, text(), Bytes::from(listing));
    }
    match method {
        Some(HttpMethod::Get) => respond(request, text(), Bytes::from_static(b"spec ok")),
        Some(HttpMethod::Head) => respond(request, text(), Bytes::new()),
        Some(HttpMethod::Post) => {
            let head = with_type(heads.ok.clone(), b"application/octet-stream");
            Ok(respond_with_queue(request, head, body))
        }
        Some(HttpMethod::Options) => respond(request, allow(heads.ok.clone()), Bytes::new()),
        _ => {
            let head = status_head(405).map_err(internal)?;
            respond(request, allow(with_length(head, 0)), Bytes::new())
        }
    }
}

/// Adds the `Allow` header that `/spec` answers `OPTIONS` with.
fn allow(mut head: Box<HttpMessage>) -> Box<HttpMessage> {
    head.headers_mut().add("Allow", b"GET, HEAD, POST, OPTIONS");
    head
}

/// Reads the rest of a request body. With `keep` it returns the body, which may be
/// up to [`MAX_SPEC_BODY`] bytes, and otherwise it discards the body.
async fn read_body(request: &mut HttpSourceHolder, keep: bool) -> Result<BufQueue, HttpError> {
    let mut body = BufQueue::new(MAX_SPEC_BODY);
    loop {
        let event = request.read_body_event_unboxed(u32::MAX).await?;
        let eom = event.eom();
        match event.into_kind() {
            HttpBodyEventKind::Body(mut chunk) if keep => {
                body.append(&mut chunk).map_err(internal)?
            }
            HttpBodyEventKind::Suspend(resume) => {
                resume.await;
            }
            HttpBodyEventKind::Body(_)
            | HttpBodyEventKind::Padding(_)
            | HttpBodyEventKind::Trailers(_) => {}
            HttpBodyEventKind::Upgrade | HttpBodyEventKind::PushPromise(_) => {
                return Err(internal("unexpected event in a request body"));
            }
        }
        if eom {
            return Ok(body);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::future::Future;
    use std::pin::Pin;
    use std::task::Waker;

    use roxygen_core::events::HttpBodyEventKind;
    use roxygen_core::fixed_source::HttpFixedSource;
    use roxygen_core::http::HttpMethod;

    use super::*;

    #[test]
    fn query_parsing() {
        assert_eq!(query_ints(b"a=13&b=42", [b"a", b"b"]), [13, 42]);
        assert_eq!(query_ints(b"b=42&a=13", [b"a", b"b"]), [13, 42]);
        assert_eq!(query_ints(b"ab=1&b=2", [b"a"]), [0], "ab= is not a=");
        assert_eq!(query_ints(b"", [b"m"]), [0]);
        assert_eq!(
            query_ints(b"a&a=5", [b"a"]),
            [5],
            "a pair without = is skipped"
        );
        assert_eq!(query_ints(b"a=x&a=5", [b"a"]), [0], "the first a= decides");
        assert_eq!(query_ints(b"a=1=2&b=-3", [b"a", b"b"]), [0, -3]);
        assert_eq!(query_ints(b"=4&a=", [b"a"]), [0]);
    }

    #[test]
    fn integers_parse_as_str_parse_does() {
        let mut texts: Vec<Vec<u8>> = [
            "0",
            "-0",
            "+0",
            "007",
            "+",
            "-",
            "+-1",
            "--1",
            " 1",
            "1 ",
            "1_0",
            "9223372036854775807",
            "+9223372036854775807",
            "9223372036854775808",
            "-9223372036854775808",
            "-9223372036854775809",
            "00000000000000000000000000042",
            "99999999999999999999",
            "١",
        ]
        .iter()
        .map(|text| text.as_bytes().to_vec())
        .collect();
        texts.push(vec![b'1', 0xff]);
        let alphabet = [b'0', b'5', b'9', b'+', b'-', b'a', b'/', b':', 0xc3];
        for length in 0..=3 {
            for mut index in 0..alphabet.len().pow(length) {
                let mut text = Vec::new();
                for _ in 0..length {
                    text.push(alphabet[index % alphabet.len()]);
                    index /= alphabet.len();
                }
                texts.push(text);
            }
        }
        for text in texts {
            let expected = std::str::from_utf8(&text)
                .ok()
                .and_then(|text| text.parse::<i64>().ok());
            assert_eq!(parse_i64(&text), expected, "{text:?}");
        }
    }

    #[test]
    fn decimals_match_to_string() {
        for value in [
            0,
            1,
            -1,
            9,
            10,
            -10,
            42,
            99,
            100,
            -12345,
            i64::MAX,
            i64::MIN,
        ] {
            assert_eq!(Decimal::new(value).as_bytes(), value.to_string().as_bytes());
        }
        for value in [0, 7, 1000, usize::MAX] {
            assert_eq!(
                Decimal::length(value).as_bytes(),
                value.to_string().as_bytes()
            );
        }
    }

    fn read_head(source: &mut HttpSourceHolder) -> HttpHeaderEvent {
        let mut context = Context::from_waker(Waker::noop());
        let mut read = source.read_header_event_unboxed();
        match Pin::new(&mut read).poll(&mut context) {
            Poll::Ready(result) => result.expect("the response has a head"),
            Poll::Pending => panic!("an in-memory head is ready"),
        }
    }

    /// The header fields other than `Content-Length`. `HttpFixedSource` adds it to
    /// every body, while these responses send it only on bodies without a type,
    /// since END_STREAM already ends an HTTP/2 body.
    fn header_list(head: &HttpMessage) -> Vec<(Vec<u8>, Vec<u8>)> {
        head.headers()
            .iter()
            .filter(|&(code, _, _)| code != HttpHeaderCode::ContentLength)
            .map(|(_, name, value)| (name.to_vec(), value.to_vec()))
            .collect()
    }

    /// A response built from a new message and sent through `HttpFixedSource`.
    fn fixed_response(content_type: Option<&[u8]>, status: u16, body: &[u8]) -> HttpSourceHolder {
        let mut head = HttpMessage::new();
        head.set_status_code(status).unwrap();
        head.set_status_message(HttpMessage::default_reason(status))
            .unwrap();
        head.set_http_version(1, 1);
        if let Some(content_type) = content_type {
            head.headers_mut()
                .add(HttpHeaderCode::ContentType, content_type);
        }
        let body = BufQueue::copy_from_slice(body, body.len()).unwrap();
        HttpSourceHolder::new(Box::new(HttpFixedSource::new(head, Some(body))))
    }

    fn contents(body: &BufQueue) -> Vec<u8> {
        body.segments()
            .flat_map(|segment| segment.to_vec())
            .collect()
    }

    fn assert_same_response(mut actual: HttpSourceHolder, mut expected: HttpSourceHolder) {
        let mut actual_head = read_head(&mut actual);
        let mut expected_head = read_head(&mut expected);
        assert_eq!(actual_head.eom(), expected_head.eom());
        assert_eq!(
            actual_head.headers_mut().status_code().unwrap(),
            expected_head.headers_mut().status_code().unwrap()
        );
        assert_eq!(
            actual_head.headers_mut().status_message().unwrap(),
            expected_head.headers_mut().status_message().unwrap()
        );
        assert_eq!(
            actual_head.headers().http_version(),
            expected_head.headers().http_version()
        );
        assert_eq!(
            header_list(actual_head.headers()),
            header_list(expected_head.headers())
        );
        if actual_head.eom() {
            return;
        }
        assert!(actual.polls_body_events());
        let mut context = Context::from_waker(Waker::noop());
        let mut actual_body = Vec::new();
        loop {
            let Poll::Ready(event) = actual.poll_body_event_exclusive(&mut context, 1) else {
                panic!("an in-memory body is ready");
            };
            let event = event.expect("a body event");
            let HttpBodyEventKind::Body(chunk) = event.kind() else {
                panic!("only body events");
            };
            actual_body.extend(contents(chunk));
            if event.eom() {
                break;
            }
        }
        let mut read = expected.read_body_event_unboxed(u32::MAX);
        let Poll::Ready(Ok(event)) = Pin::new(&mut read).poll(&mut context) else {
            panic!("the fixed body is ready");
        };
        let HttpBodyEventKind::Body(chunk) = event.kind() else {
            panic!("a fixed body event");
        };
        assert_eq!(actual_body, contents(chunk));
        assert!(!actual.readable(), "EOM retires the response");
    }

    fn request() -> HttpSourceHolder {
        let source = HttpFixedSource::make_get_request("/", None).unwrap();
        let mut holder = HttpSourceHolder::new(Box::new(source));
        read_head(&mut holder);
        holder
    }

    #[test]
    fn responses_match_fixed_source_responses() {
        let heads = Heads::new().unwrap().for_worker();
        for (query, body) in [
            (&b"a=13&b=42"[..], &b"55"[..]),
            (b"a=-5", b"-5"),
            (b"", b"0"),
            (b"a=9223372036854775807&b=1", b"-9223372036854775808"),
        ] {
            let response = baseline(&heads, request(), query).unwrap();
            assert_same_response(response, fixed_response(Some(b"text/plain"), 200, body));
        }
        let response = respond(request(), heads.not_found.clone(), Bytes::new()).unwrap();
        assert_same_response(response, fixed_response(None, 404, b""));
        let body = br#"{"items":[],"count":0}"#;
        let head = with_type(heads.ok.clone(), b"application/json");
        let response = respond(request(), head, Bytes::from_static(body)).unwrap();
        assert_same_response(
            response,
            fixed_response(Some(b"application/json"), 200, body),
        );
    }

    /// A request whose body is never read, which records how it is stopped.
    struct UnreadBody {
        head: Option<HttpHeaderEvent>,
        stopped: Rc<Cell<Option<Option<HttpErrorCode>>>>,
    }

    impl HttpSource for UnreadBody {
        fn read_header_event(&mut self) -> LocalSourceFuture<Result<HttpHeaderEvent, HttpError>> {
            Box::pin(ready(Ok(self.head.take().unwrap())))
        }

        fn read_body_event(
            &mut self,
            _maximum: u32,
        ) -> LocalSourceFuture<Result<HttpBodyEvent, HttpError>> {
            Box::pin(std::future::pending())
        }

        fn stop_reading(&mut self, error: Option<HttpErrorCode>) {
            assert!(self.stopped.replace(Some(error)).is_none(), "stopped once");
        }
    }

    #[test]
    fn a_response_stops_an_unread_request_body() {
        let heads = Heads::new().unwrap();
        let mut message = HttpMessage::new();
        message.set_url("/baseline2?a=1", false).unwrap();
        message.set_method(HttpMethod::Post).unwrap();
        let stopped = Rc::new(Cell::new(None));
        let mut request = HttpSourceHolder::new(Box::new(UnreadBody {
            head: Some(HttpHeaderEvent::new(message, false).unwrap()),
            stopped: Rc::clone(&stopped),
        }));
        assert!(!read_head(&mut request).eom());
        let response = baseline(&heads, request, b"a=1").unwrap();
        assert_eq!(
            stopped.get(),
            Some(None),
            "stopped as a dropped holder stops it"
        );
        assert_same_response(response, fixed_response(Some(b"text/plain"), 200, b"1"));
    }

    #[test]
    fn a_response_head_is_read_once() {
        let heads = Heads::new().unwrap();
        let mut response = baseline(&heads, request(), b"a=1").unwrap();
        read_head(&mut response);
        let mut source = Response {
            head: None,
            body: BufQueue::new(0),
        };
        let mut context = Context::from_waker(Waker::noop());
        let Poll::Ready(Err(error)) = source.read_header_event().as_mut().poll(&mut context) else {
            panic!("a second header read fails");
        };
        assert_eq!(error.code(), HttpErrorCode::INVALID_STATE_TRANSITION);
    }
}
