# tako

[Tako](https://github.com/rust-dd/tako) 2.4.1 (`tako-rs` on crates.io) on hyper and Tokio, default configuration.
gRPC lives in [`tako-grpc`](../tako-grpc) and the gateway stacks in [`tako-gateway`](../tako-gateway);
all three report as `tako`.

## Stack

- **Language:** Rust 1.99
- **Framework:** tako-rs 2.4.1
- **Build:** Multi-stage, `debian:trixie-slim` runtime

## Listeners

| Port | Protocol | Server |
|------|----------|--------|
| 8080 | HTTP/1.1, WebSocket | `tako::serve_per_thread` with `PerThreadConfig::default()` |
| 8081 | HTTP/1.1 over TLS | `Server::spawn_tls` |
| 8082 | h2c (prior knowledge) | `Server::spawn_h2c` |
| 8443/tcp | h2 over TLS | `Server::spawn_tls` |
| 8443/udp | HTTP/3 | `Server::spawn_h3` |

The TLS and QUIC listeners start only when `/certs` is mounted, so the server
behind the gateway edge listens in cleartext only.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums the `a` and `b` query parameters |
| `/baseline11` | POST | Sums the query parameters and the request body |
| `/baseline2` | GET | Sums the `a` and `b` query parameters |
| `/delay/{ms}` | GET | Waits `ms` milliseconds, then returns `ms` |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` (`m` defaults to 1) |
| `/echo` | POST | Returns the request body verbatim |
| `/static/{*path}` | GET | Files under `/data/static` |
| `/async-db?min=&max=&limit=` | GET | Postgres price-range query |
| `/ws` | GET | WebSocket echo |
| `/public/baseline`, `/public/json/{count}` | GET | Production-stack public routes |
| `/api/items/{id}` | GET, POST | Production-stack cache-aside read and write |
| `/api/me` | GET | Production-stack user lookup by `X-User-Id` |

## Notes

- Routing and extraction through tako's `Path`, `Query`, `State`, body and
  header extractors; JSON through the `Json` responder, serialized by serde per
  request
- Compression through tako's compression plugin with default settings (brotli or
  gzip at level 5), attached to the JSON routes only
- Static files through tako's `ServeDir` with `PrecompressedPolicy::both()`,
  which picks the `.br`/`.gz` sibling from `Accept-Encoding` and reads from disk
  on every request
- WebSocket through `TakoWs`, echoing text and binary frames
- Postgres through deadpool-postgres and tokio-postgres, pool sized from
  `DATABASE_MAX_CONN`, statements prepared once per connection
- Production-stack reads are cache-aside in process (moka, 1 s TTL for items,
  30 s for users) and writes invalidate the item
