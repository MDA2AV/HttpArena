# ntex

ntex 4 on its native runtime.

## Stack

- **Language:** Rust 1.97
- **Framework:** ntex 4 (`ntex::web`)
- **Runtime:** Native ntex executor and networking
- **Build:** Multi-stage, `debian:bookworm-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (h2 on 8443) |
| `/pipeline` | GET | Returns `ok` |
| `/delay/{ms}` | GET | Asynchronously waits `ms` milliseconds and returns the delay |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{name}` | GET | Serves `/data/static/{name}` from disk, preferring a `.br`/`.gz` sibling |
| `/async-db?min=&max=&limit=` | GET | Items with `price` in range from Postgres, up to `limit` (1-50) |
| `/fortunes` | GET | Fortune rows from Postgres plus a runtime row, sorted and rendered as HTML |

The same routes are served over TLS with HTTP/1.1 on port 8081 (`json-tls`,
`static-tls`, `8gbit`) and with h2 on port 8443 (`baseline-h2`, `static-h2`).

## Notes

- Default worker count and HTTP settings; backlog 1024 and 8 accept threads,
  each with its own `SO_REUSEPORT` listener. The server is assembled with
  `ntex::server::build()` because `web::HttpServer` does not expose the accept
  thread count
- Timer resolution is 2 ms instead of the default 16 ms
- Write buffers use 4 KiB pages on 8080, where responses are small and larger
  bodies are appended as separate pages without copying, and 16 KiB pages on
  the TLS ports to match rustls record sizes
- On Linux the native runtime selects io-uring when available and falls back to
  polling; other Unix platforms use polling
- Routing and extraction through `ntex::web` resources and the `Query`, `Path`,
  and `Bytes` extractors
- JSON serialized per request through `HttpResponse::json` using serde_json;
  field order is the struct order
- `Compress::default()` on the JSON resource handles content negotiation and
  per-request compression. Its default gzip encoder uses level 1; bodies below
  the framework's compression threshold remain uncompressed
- The dataset is leaked once at startup so responses borrow it rather than
  cloning every string
- `PayloadConfig` in `WebAppConfig` is raised to 64 MiB to support 20 MiB uploads
- json-tls on 8081 through rustls with ring, ALPN pinned to `http/1.1` so an
  h2-capable client is never offered the upgrade on the HTTP/1.1 port
- h2 on 8443 through the same rustls setup with ALPN `h2, http/1.1`; ntex
  picks HTTP/2 or HTTP/1.1 from the negotiated protocol
- Static files are opened per request through `ntex_files::NamedFile`, so a
  replaced file is served immediately. ntex-files has no precompressed API, so
  the handler picks the best `.br`/`.gz` sibling accepted by `Accept-Encoding`
  (q-values honoured, `br` wins ties), keeps the original file's
  `Content-Type`, and sets `Content-Encoding` and `Vary: accept-encoding`.
  No on-the-fly compression on this route
- `/async-db` uses tokio-postgres on the native ntex runtime: connections are
  ntex `Io` streams, which implement tokio's `AsyncRead`/`AsyncWrite` through
  ntex-io's `tokio` feature, so no tokio runtime is started. Each worker keeps
  a `deadpool::unmanaged::Pool` of `DATABASE_MAX_CONN / workers` connections
  (default 256 in total) with the query prepared once per connection.
  Connections open in the background and retry every second; until one is
  ready, or if `DATABASE_URL` is unset, the endpoint returns
  `{"items":[],"count":0}`. A closed connection is dropped from the pool and
  reopened
- `/fortunes` runs `SELECT id, message FROM fortune` on a statement prepared
  once per connection, appends the runtime row, sorts by message in byte order
  and renders the Askama template `templates/fortunes.html` into a
  pre-sized buffer. `askama.toml` registers an escaper that writes named
  entities (`&lt;`) instead of Askama's numeric ones. Without a database the
  page holds only the runtime row
- A missing `/certs` leaves the TLS listeners down instead of aborting startup:
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
- Docker release builds use `target-cpu=native` and ThinLTO, together with the
  manifest's `opt-level=3` and `codegen-units=1`.
