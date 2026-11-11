# rama

[Rama](https://github.com/plabayo/rama) 0.4 on the multi-threaded Tokio runtime, default configuration.

## Stack

- **Language:** Rust 1.99
- **Framework:** rama 0.4 (`http-full`, `rustls`, `aws-lc`)
- **Build:** Multi-stage, `debian:trixie-slim` runtime

## Listeners

| Port | Protocol |
|------|----------|
| 8080 | HTTP/1.1 and WebSocket |
| 8081 | HTTP/1.1 over TLS (ALPN `http/1.1`) |
| 8082 | h2c prior knowledge |
| 8443 | HTTP/2 over TLS (ALPN `h2`) |

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values |
| `/delay/{ms}` | GET | Waits `ms` milliseconds, returns `ms` |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/*` | GET | Files from `/data/static` |
| `/ws` | GET | WebSocket echo |

## Notes

- One rama web `Router` serves every listener; routing and extraction through its `Path`, `Query`, `State` and `Bytes` extractors
- JSON through the rama `Json` response, serialized by serde per request
- Compression through the rama `CompressionLayer`
- Static files through rama `ServeDir`, which serves the `.br`/`.gz` siblings on disk when the client accepts them
- WebSocket echo through the rama-ws `WebSocketAcceptor` echo service
- The dataset is leaked once at startup so responses borrow it instead of cloning
