# tako

[Tako](https://github.com/rust-dd/tako) 2.4 (`tako-rs` on crates.io) on hyper and Tokio, default configuration.

## Stack

- **Language:** Rust 1.99
- **Framework:** tako-rs 2.4
- **Build:** Multi-stage, `debian:trixie-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums the `a` and `b` query parameters |
| `/baseline11` | POST | Sums the query parameters and the request body |
| `/delay/{ms}` | GET | Waits `ms` milliseconds, then returns `ms` |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body verbatim |
| `/static/{*path}` | GET | Files under `/data/static` |

## Notes

- Port 8080 runs `tako::serve_per_thread` with `PerThreadConfig::default()`:
  one current-thread Tokio runtime per CPU, each with its own `SO_REUSEPORT`
  listener, and new connections handed to the least busy worker
- Port 8081 (`json-tls`, `8gbit`, `static-tls`) runs `tako::Server::spawn_tls`
  with rustls on a multi-thread Tokio runtime, because the per-thread workers
  serve plaintext HTTP/1.1 only. ALPN advertises `http/1.1`
- Routing and extraction through tako's `Path`, `Query`, `State` and body
  extractors; JSON through the `Json` responder, serialized by serde per request
- Compression through tako's compression plugin with default settings
  (brotli or gzip at level 5), attached to the `/json/{count}` route
- Static files through tako's `ServeDir` with `PrecompressedPolicy::both()`,
  which picks the `.br`/`.gz` sibling from `Accept-Encoding` and reads from
  disk on every request
