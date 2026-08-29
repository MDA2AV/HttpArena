# hyper

Low-level Rust HTTP library built on tokio with multi-threaded async runtime and rustls for TLS.

## Stack

- **Language:** Rust 1.88
- **Engine:** hyper + tokio
- **TLS:** tokio-rustls
- **Build:** Multi-stage, `debian:bookworm-slim` runtime, `-C target-cpu=native`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json` | GET | Processes 50-item dataset, serializes JSON |
| `/compression` | GET | Gzip-compressed large JSON response |
| `/db` | GET | SQLite range query with JSON response |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{filename}` | GET | Serves preloaded static files with MIME types |

## Notes

- `service_fn` pattern for request dispatch
- HTTP/1 and HTTP/2 support
- `SO_REUSEPORT` via socket2 crate
- Static files preloaded into memory at startup
- Tokio multi-threaded async runtime
