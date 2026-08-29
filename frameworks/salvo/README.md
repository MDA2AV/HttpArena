# salvo

Salvo 0.96 on tokio and hyper, default configuration.

## Stack

- **Language:** Rust 1.94
- **Framework:** Salvo 0.96
- **Build:** Multi-stage, `debian:bookworm-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- Routing through Salvo's `Router` tree with a `{count}` path parameter
- JSON through Salvo's own `Json` responder, serialized by serde per request
- Compression through the built-in `Compression` hoop, gzip and brotli at
  `CompressionLevel::Fastest`, which is level 1 and what the profile asks for.
  `Minsize` would score better on the bandwidth term and is not the rule
- The hoop wraps `/json` only, so the other routes stay on the plain write path
- The dataset is parsed once into a `OnceCell` and responses borrow from it
  rather than cloning every string
- Body reads are capped at 64 MB; the default rejects the 20 MB upload
- json-tls on 8081 through Salvo's rustls acceptor, serving the same router
- A missing `/certs` leaves the TLS listener down instead of aborting startup:
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
