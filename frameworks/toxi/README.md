# toxi

Toxi on hyper with the multi-threaded Tokio runtime, default configuration.

## Stack

- **Language:** Rust 1.98
- **Framework:** Toxi 3.x (hyper engine)
- **Build:** Multi-stage, static musl binary on `alpine:3.19`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + JSON integer body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m`, gzip per request |
| `/delay/{ms}` | GET | Async sleep, echoes milliseconds |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Routing and extraction through Toxi's `Path`, `Query`, and body extractors
- JSON serialized per request with serde_json
- Compression is manual gzip per request (tower-http's `CompressionLayer`
  changes the body type and cannot wrap Toxi responses, so the handler
  compresses with flate2 and sets `Content-Encoding` itself)
