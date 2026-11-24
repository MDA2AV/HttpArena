# barejs

High-performance JIT-specialized web framework for Bun with zero-allocation context pooling, built-in compression middleware, static file handler, and native WebSocket support.

## Stack

- **Language:** TypeScript
- **Runtime:** Bun 1.4.4
- **Framework:** [BareJS](https://github.com/xarhang/bareJS) 0.1.59
- **Server:** `app.listen()` from `barejs`, running on Bun's native HTTP server with one `reusePort` worker process per available CPU core
- **Templates:** Handlebars (`views/fortunes.hbs`)

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/delay/:ms` | GET | Waits for `ms` milliseconds asynchronously without blocking the event loop |
| `/baseline11` | GET/POST | Sums query parameters, plus the POST body |
| `/baseline2` | GET | Sums query parameters for the HTTP/2 and HTTP/3 baseline routes |
| `/json/:count` | GET | Serializes a slice of the mounted dataset with `total` computed from `m`, compressed per request via BareJS `compress()` middleware |
| `/echo` | POST | Echoes the request body byte-for-byte |
| `/static/:name` | GET | Serves files from `/data/static` via BareJS `staticFile()` and pre-compressed `.br`/`.gz` variants |
| `/async-db` | GET | Parameterized Postgres range query over `items` via `Bun.SQL` |
| `/fortunes` | GET | Queries Postgres and renders the sorted fortunes table with Handlebars (including HTML escaping) |
| `/ws` | GET (WS) | WebSocket echo server using BareJS `app.ws("/ws", ...)` |
| `/spec`, `/spec/headers` | GET/HEAD/OPTIONS/POST | Protocol compliance endpoints for `h1` and `h2` suites |

## Notes

- Multi-process clustering spawns one worker per available CPU core (respecting `/sys/fs/cgroup/cpu.max`), sharing ports via `SO_REUSEPORT`.
- `compress()` is BareJS's built-in compression middleware, scoped to `/json/:count` to negotiate `br` and `gzip` per request.
- Postgres connections use `Bun.SQL` with `DATABASE_MAX_CONN` divided evenly across worker processes.
- HTTP/1.1 runs on port `8080` (and `8081` over TLS), HTTP/2 cleartext (`h2c`) on `8082`, and HTTP/2 + HTTP/3 over TLS/QUIC on `8443`.
