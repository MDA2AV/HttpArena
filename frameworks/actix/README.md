# actix

Actix-web 4 HTTP server with rustls for TLS/HTTP/2 support, compiled with thin LTO and `-C target-cpu=native`.

## Stack

- **Language:** Rust 1.88
- **Framework:** Actix-web 4
- **TLS:** rustls
- **Build:** Multi-stage, `debian:bookworm-slim` runtime

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

- Per-worker SQLite connections via thread-local storage
- Backlog set to 4096 for connection queuing
- Static files preloaded into memory at startup
- Gzip compression level 1
