# trillium

Trillium 1.x async Rust web framework on tokio.

## Stack

- **Language:** Rust 1.94
- **Engine:** trillium-http (h1 + h2 prior-knowledge), trillium-quinn (h3)
- **TLS:** trillium-rustls (h1 + h2 via ALPN), trillium-quinn for QUIC
- **gRPC:** trillium-grpc (`benchmark.BenchmarkService` over h2c + h2/TLS)
- **JSON:** sonic-rs
- **DB:** deadpool-postgres + tokio-postgres
- **Build:** Multi-stage, `debian:bookworm-slim` runtime, `-C target-cpu=native`

## Listeners

| Port | Protocol | Notes |
|------|----------|-------|
| 8080 | HTTP/1.1 cleartext + WebSocket | `/ws` upgrade |
| 8081 | HTTP/1.1 + TLS | ALPN advertises `http/1.1` only |
| 8443 | HTTP/1.1 + HTTP/2 + HTTP/3 | TLS via ALPN; QUIC via UDP |

gRPC shares these listeners: `unary-grpc` / `stream-grpc` run over h2c prior-knowledge on 8080, and `unary-grpc-tls` / `stream-grpc-tls` over h2-via-ALPN on 8443.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET / POST | Sums query parameter values; POST adds the body |
| `/baseline2` | GET | Same shape as `/baseline11` GET, exercised over h2/h3 |
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/json/:count` | GET | Loads `:count` items from `/data/dataset.json`, computes `total = price * quantity * m` |
| `/upload` | POST | Streams the request body and returns the byte count |
| `/static/*` | GET | Serves files from `/data/static` via `trillium-static` |
| `/async-db` | GET | Postgres range query via deadpool-postgres pool |
| `/crud/items` | GET / POST | Paginated list / upsert |
| `/crud/items/:id` | GET / PUT | Cached read (200 ms TTL) / update with cache invalidation |
| `/ws` | GET (upgrade) | WebSocket echo |

## gRPC — `benchmark.BenchmarkService`

| RPC | Shape | Description |
|-----|-------|-------------|
| `GetSum` | unary | Returns `a + b` |
| `StreamSum` | server-streaming | Emits `count` replies of `a + b` |
| `CollectSum` | client-streaming | Sums `a + b` over all requests, one reply |
| `EchoSum` | bidirectional | One `a + b` reply per request |

## Notes

- Trillium serves h1.1, h2 (TLS+ALPN or prior-knowledge), and h3 from the same handler tree — endpoint code is protocol-agnostic.
- The gRPC service is just another `Handler` in the tuple (`trillium-grpc`'s generated `BenchmarkServiceServer`), mounted first so its `/benchmark.BenchmarkService/*` paths are handled before compression/routing and all other requests pass through. The service module is checked in at `src/grpc/benchmark.rs`, generated from `proto/benchmark.proto`.
- Compression is wired via `trillium-compression` middleware: gzip/brotli on demand per `Accept-Encoding`. No `Content-Encoding` is set when the client doesn't advertise one.
- Static files are read from disk on every request (`trillium-static::files`).
- Dataset (`/data/dataset.json`) is loaded once at startup; per-request totals are computed and the response is serialized fresh each request.
- The CRUD cache is in-process (`DashMap`, 200 ms TTL).
- The async-db handler returns `{"items":[],"count":0}` and logs a warning if the pool is unavailable, per the implementation guidelines.
