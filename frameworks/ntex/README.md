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
| `/delay/{ms}` | GET | Asynchronously waits `ms` milliseconds and returns the delay |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

The same routes are served over TLS on port 8081 for `json-tls` and `8gbit`.

## Notes

- Default worker count, CPU affinity, connection distribution, backlog, and HTTP
  settings
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
- A missing `/certs` leaves the TLS listener down instead of aborting startup:
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
- Docker release builds use `target-cpu=native` and ThinLTO, together with the
  manifest's `opt-level=3` and `codegen-units=1`.
