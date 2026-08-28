# axum

Axum 0.8 on hyper with the multi-threaded Tokio runtime, default configuration.

## Stack

- **Language:** Rust 1.94
- **Framework:** Axum 0.8
- **Build:** Multi-stage, `debian:bookworm-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- Routing and extraction through the Axum `Path`, `Query` and body extractors
- JSON through the `Json` response, serialized by serde per request
- Compression through the tower-http `CompressionLayer`
- The dataset is leaked once at startup so responses borrow it instead of cloning
- One SO_REUSEPORT listener per core on 8080, each with its own `axum::serve`
  accept loop. `axum::serve` accepts on a single task, which is free while
  connections are held and expensive once they churn: the profiles that
  reconnect (`json` at `-r 25`, `limited-conn` at `-r 10`) left most of the box
  idle, while `json-tls`, which holds connections, saturated it. Letting the
  kernel balance across per-core queues is the same thing bun, go-fasthttp,
  hono-bun and fletch do here
- json-tls on 8081 keeps axum-server's single accept loop: that profile holds
  its connections, so there is nothing for a second queue to spread
