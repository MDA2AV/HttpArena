# cpeak

[Cpeak for Rust](https://github.com/Cododev-Technology/cpeak/tree/main/rust), the Rust version of the Cpeak Node.js framework: an Express-style API (routes, middleware, `req` and `res`) on hyper, with one single-threaded Tokio event loop per core. Default configuration.

## Stack

- **Language:** Rust 1.94
- **Framework:** Cpeak
- **Engine:** hyper 1 (HTTP/1.1)
- **TLS:** rustls (ring), through Cpeak's `https` option
- **Build:** Multi-stage, `debian:bookworm-slim` runtime

## Endpoints

| Endpoint                        | Method | Description                                                     |
| ------------------------------- | ------ | --------------------------------------------------------------- |
| `/pipeline`                     | GET    | Returns `ok` (plain text)                                       |
| `/baseline11`                   | GET    | Sums query parameter values                                     |
| `/baseline11`                   | POST   | Sums query parameters + request body                            |
| `/delay/{ms}`                   | GET    | Waits `ms` milliseconds, returns the number                     |
| `/json/{count}?m=N`             | GET    | First `count` dataset items with `total = price * quantity * m` |
| `/echo`                         | POST   | Returns the request body back verbatim                          |
| `/async-db?min=X&max=Y&limit=N` | GET    | Postgres range query with JSON response                         |

Port 8080 is HTTP and port 8081 is the same app over HTTPS (HTTP/1.1, ALPN `http/1.1`), with the certificate and key mounted at `/certs`.

## Notes

- Everything goes through Cpeak's documented API, in its default configuration: the router for the paths, `req.params` and `req.query` for the path and query parameters, `req.chunk()` for the request bodies, `res.json()` and `res.end()` for the responses
- JSON is serialized per request by `res.json()`, and compressed per request by Cpeak's own compression, switched on with its default options
- `/delay/{ms}` waits with `cpeak::sleep`, which parks the request and not the thread
- The worker count is Cpeak's default: one per core, each with its own `SO_REUSEPORT` listener on Linux. There is no socket code in the entry
- A Cpeak app speaks either HTTP or HTTPS, so the routes are in a function that builds the app once for each port
- mimalloc is Cpeak's default allocator
- `/async-db` uses tokio-postgres with deadpool, one pool per worker thread, sized from `DATABASE_MAX_CONN`
