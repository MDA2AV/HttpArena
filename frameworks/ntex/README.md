# ntex

ntex 2 on its own tokio-backed runtime, default configuration.

## Stack

- **Language:** Rust 1.94
- **Framework:** ntex 2 (`ntex::web`)
- **Build:** Multi-stage, `debian:bookworm-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- Routing and extraction through `ntex::web` resources and the `Path` extractor
- JSON serialized by serde_json from a struct, so the field order is the struct order
- gzip for `json-comp` is negotiated in the handler and encoded at level 1, the
  level the profile asks for; ntex's `Compress` middleware fixes the level instead
- The dataset is leaked once at startup so responses borrow it rather than
  cloning every string
- `PayloadConfig` is raised to 64 MB; the default rejects the 20 MB upload
- json-tls on 8081 through rustls with ring, ALPN pinned to `http/1.1` so an
  h2-capable client is never offered the upgrade on the HTTP/1.1 port
- A missing `/certs` leaves the TLS listener down instead of aborting startup:
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
- No `target-cpu=native` and no LTO in the build. This framework has a history
  of tripping a rustc SIGSEGV and a GCC ICE with both on, and neither is needed
  for this workload
