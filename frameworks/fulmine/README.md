# fulmine.js

A drop-in replacement for Express 5 running on uWebSockets.js, with its own `cluster` option for multi-core scaling.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [fulmine.js](https://github.com/nigrosimone/fulmine.js) (Express 5 API on uWebSockets.js)
- **Build:** multi-stage, `node:26-trixie-slim` for both stages

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/json/:count` | GET | Serializes a slice of the dataset, gzip when the client accepts it |
| `/delay/:ms` | GET | Waits the milliseconds named in the path, then echoes them back |
| `/async-db` | GET | Reads from PostgreSQL with a prepared statement |
| `/fortunes` | GET | PostgreSQL rows rendered with EJS |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/*` | GET | `express.static()` with `preCompressed`, serves the `.br` or `.gz` on disk |
| `/ws` | WS | Echoes every frame |
| `/public/*`, `/api/*` | GET/POST | production-stack routes, Redis cache in front of PostgreSQL |

## Notes

A standard entry: every route uses a documented framework API, nothing is hand-rolled. The settings
and why they are there are in the framework's
[Performance tips](https://fulmine.sndesign.it/performance#performance-tips).

- `express({ cluster: "auto" })` forks one worker per usable core (cgroup quota first), each binding
  the same port with `SO_REUSEPORT`, and `app.cluster.share()` splits the Postgres connections
  between them: [cluster](https://fulmine.sndesign.it/examples/cluster),
  [a pool per worker](https://fulmine.sndesign.it/examples/cluster-pool).
- Routes are matched by the uWS router, and `/pipeline` is compiled to a uWS declarative response:
  [fast routes](https://fulmine.sndesign.it/examples/fast-routes).
- `express.compression()` and `express.static({ preCompressed: true })` are the framework's own:
  [compression](https://fulmine.sndesign.it/examples/compression),
  [pre-compressed files](https://fulmine.sndesign.it/examples/static-precompressed).
- `tls_check`: the listener on :9000 reads `/certs-tls`, and a rotation is a new listener on the
  shared port followed by `close()` on the old one, since uWS reads the pair only when it builds
  the SSL context.
- HTTP/2 (`baseline-h2`, `static-h2` on :8443, `baseline-h2c`, `json-h2c` on :8082): uWS has no
  HTTP/2, so the same app is handed to `node:http2` with its defaults, one socket per worker with
  `SO_REUSEPORT`: [node:http2](https://fulmine.sndesign.it/examples/node-http#http-2).
- `/json` on the TLS listener has no `compression()`: json-tls never sends `Accept-Encoding`.
  The production-stack item cache lives one second, the profile's limit.
