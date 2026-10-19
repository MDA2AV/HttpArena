# spliffy

Directory based routing on uWebSockets.js: a route is a file under `www/`, a handler returns
the response, and static files and WebSockets live in the same tree.

## Stack

- Language: JavaScript
- Runtime: Node.js 26
- Framework: [spliffy](https://github.com/SRFNStack/spliffy) on uWebSockets.js
- Build: multi stage, `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | File | Description |
|----------|--------|------|-------------|
| `/pipeline` | GET | `www/pipeline.rt.mjs` | `ok`, a declarative response answered inside uWebSockets.js |
| `/baseline11` | GET/POST | `www/baseline11.rt.mjs` | sum of the query values, plus the body for POST |
| `/baseline2` | GET | `www/baseline2.rt.mjs` | sum of the query values |
| `/json/:count` | GET | `www/json/$count.rt.mjs` | the first `count` items with `total = price * quantity * m`, compressed when accepted |
| `/delay/:ms` | GET | `www/delay/$ms.rt.mjs` | waits `ms` milliseconds, answers with `ms` |
| `/async-db` | GET | `www/async-db.rt.mjs` | a range scan on Postgres through `pg`, prepared statements, pool sized from `DATABASE_MAX_CONN` |
| `/fortunes` | GET | `www/fortunes.rt.mjs` | Postgres read, runtime row, ordinal sort, rendered with EJS |
| `/echo` | POST | `www/echo.rt.mjs` | the request body, byte for byte |
| `/static/*` | GET | `www/static` | spliffy's static files from the mounted `/data/static`, `.br` and `.gz` twins by accept-encoding |
| `/ws` | WebSocket | `www/ws.rt.mjs` | echo |

## Notes

A standard entry: every route is a documented spliffy feature, nothing reaches around the
framework.

- Routing is the directory tree. `www/json/$count.rt.mjs` is `/json/:count`, the parameter is
  read with `url.param('count')` and the query with `url.query`.
- A handler returns its response: a string, a `Buffer`, an object serialized to JSON, a stream,
  or a `{ statusCode, headers, body }` descriptor. The body of a POST is parsed before the handler
  runs and is `body` on the context, so the baseline and echo handlers are synchronous and answer
  with one write.
- `/pipeline` is a declarative response, spliffy's wrapper for the uWebSockets.js
  `DeclarativeResponse`: compiled once at startup and answered without entering JavaScript.
- Compression is spliffy's `compression()` middleware, on the json route only. It compresses in one
  call when the body is one piece, brotli first then gzip, and does nothing when the request sends no
  `accept-encoding`.
- Static files are served by spliffy from `www/static`, a symlink to the mounted directory. The
  cache is the framework's: it stats the file on every request and reads it again when the mtime,
  size or inode changed, so a replaced file is served on the next request. `staticPrecompressed`
  serves the `.br` or `.gz` twin on disk with the original content type. Declarative (compiled)
  static responses are off because they are read once at startup.
- TLS is the same server on 8081 (`httpsPort`, `httpRedirect: false`), uWebSockets.js's own
  BoringSSL listener with the mounted pair: TLS 1.2 and 1.3, no ALPN.
- One worker per usable core with node's `cluster`, reading the cgroup quota first. Each worker
  binds the ports with `SO_REUSEPORT`, so the primary is not in the request path.
