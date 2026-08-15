# rocket

Rocket 0.5 on hyper with the multi-threaded Tokio runtime, default configuration.

## Stack

- **Language:** Rust 1.94
- **Framework:** Rocket 0.5
- **Build:** Multi-stage, `debian:bookworm-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing, path and query guards through the Rocket attribute macros
- JSON through the `Json` responder, serialized by serde per request
- The dataset is leaked once at startup so responses borrow it instead of cloning
- No `json-comp`: Rocket 0.5 has no first-party compression, and hand-rolled gzip
  would not measure the framework
