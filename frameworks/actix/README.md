# actix

Actix-web 4 HTTP server with rustls for TLS/HTTP/2 support, compiled with thin LTO and `-C target-cpu=native`.

## Stack

- **Language:** Rust 1.94
- **Framework:** Actix-web 4
- **TLS:** rustls
- **Allocator:** mimalloc
- **Build:** Multi-stage, `debian:trixie-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/delay/{ms}` | GET | Asynchronously waits `ms` milliseconds and returns the delay |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{name}` | GET | Serves `/data/static/{name}` from disk, preferring a `.br`/`.gz` sibling |
| `/async-db?min=&max=&limit=` | GET | Items with `price` in range from Postgres, up to `limit` (1-50) |
| `/fortunes` | GET | Fortune rows from Postgres plus a runtime row, sorted and rendered as HTML |

The same routes are served over TLS on port 8081 (`json-tls`, `static-tls`,
`8gbit`) and on port 8443 (`baseline-h2`, `static-h2`). The h2c profiles are
served by the `actix-h2c` entry and WebSocket by `actix-websocket`.

## Notes

- Default worker count (one per CPU the container may use) and HTTP settings,
  with `TCP_NODELAY` enabled
- Routing and extraction through `web::resource`/`App::route` and the `Query`,
  `Path`, `Bytes` and `Payload` extractors
- The dataset is loaded once and leaked, so responses borrow its strings
  instead of cloning them; the JSON body is still built and serialized with
  serde_json on every request
- json-comp: gzip at level 1 is driven in the handler. Actix-web's encoder
  compresses in place only below 1 KiB and sends everything larger through
  `spawn_blocking`, and every body on this profile is 2-6 KB. The `Compress`
  middleware wraps this one route and serves any other encoding the client
  asks for; it leaves the gzip response alone because it already carries a
  `Content-Encoding`
- No other route is wrapped in `Compress`. Wrapped around the whole app it
  compressed the static files that have no pre-compressed sibling on every
  request
- Static files are opened per request through `actix_files::Files`, so a
  replaced file is served immediately. `try_compressed()` picks the `.br`/`.gz`
  sibling the client accepts
- `/async-db` uses tokio-postgres behind deadpool-postgres. Every worker is a
  single-threaded runtime, so each one keeps its own pool of
  `DATABASE_MAX_CONN / workers` connections (default 256 in total) and a query
  never leaves the thread serving its request. Statements are prepared once
  per connection through `prepare_cached`. Without `DATABASE_URL`, or when the
  pool or the query fails, the endpoint returns `500 Internal Server Error`
- `/fortunes` runs `SELECT id, message FROM fortune`, appends the runtime row,
  sorts by message in byte order and renders the Askama template
  `templates/fortunes.html`. `askama.toml` registers an escaper that writes
  named entities (`&lt;`) instead of Askama's numeric ones. Database errors
  return `500`
- Both TLS listeners use the mounted certificate through rustls with ring.
  Actix-web offers `h2` and `http/1.1` by ALPN on every rustls listener; the
  client picks
- A missing `/certs` leaves the TLS listeners down instead of aborting startup
- Docker release builds use `target-cpu=native` and ThinLTO, together with the
  manifest's `opt-level=3` and `codegen-units=1`
