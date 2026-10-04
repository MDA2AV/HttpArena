# morojs

MoroJS on its native HTTP engine, clustered by the framework itself.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [MoroJS 1.8](https://github.com/Moro-JS/moro) on `@morojs/engine`, its own native HTTP engine
- **Build:** Multi-stage on `node:26-trixie-slim`; the engine ships prebuilt binaries, so no toolchain

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values (behind the gateway proxies) |
| `/delay/:ms` | GET | Waits `ms` milliseconds on an awaited timer, then returns `ms` |
| `/json/:count` | GET | Serializes a slice of the dataset, brotli or gzip when the client asks for it |
| `/echo` | POST | Returns the request body back verbatim (TLS listener) |
| `/ws` | WebSocket | Echoes every text and binary frame unchanged |
| `/async-db` | GET | Reads from PostgreSQL through `pg`, prepared statement, pool sized under `DATABASE_MAX_CONN` |
| `/fortunes` | GET | Reads 200 rows from PostgreSQL, appends the runtime row, sorts and renders `views/fortunes.ejs` |
| `/static/:filename` | GET | Serves a file from disk through the framework's `staticFiles` middleware (TLS listener) |
| `/public/baseline`, `/public/json/:count` | GET | The baseline and JSON routes as the production-stack edge forwards them, no auth |
| `/api/items/:id` | GET/POST | Cache-aside read with `X-Cache: HIT` or `MISS`, or a JSON-body update that invalidates the entry and answers 204 |
| `/api/me` | GET | Reads the user named by `X-User-Id` through the same cache-aside |

## Notes

- Standard mode: the app is `createApp()` with its defaults on the native engine (`engine: 'moro'`,
  which is also the default). Request tracking and request logging are turned off through their
  documented options; nothing else is configured.
- `/pipeline` is a literal handler, `.handler('ok')`: the framework's static route, answered inside
  the engine without entering JS, with the same `text/plain` reply `res.send('ok')` would give.
- Clustering is Moro's own (`performance.clustering`): one worker per core, which on the native
  engine means worker threads that each bind the port through `SO_REUSEPORT`. The count is passed
  in explicitly from the cgroup quota, because Moro's `auto` counts every host core even under
  `--cpuset-cpus`.
- `json-comp` is the framework's `compression()` middleware attached to the `/json` route alone,
  so no other endpoint pays for the encoder. It negotiates off `Accept-Encoding` per request and
  leaves the body alone when the header is absent. gzip is preferred over brotli through the
  middleware's `encodings` option: at the default level it costs about half the CPU of brotli at
  the default quality for a body a tenth larger, and the profile scores bytes squared against
  rate; brotli remains available to a client that accepts nothing else.
- `UV_THREADPOOL_SIZE=64` is set in the Dockerfile. The libuv pool serves the compression and
  file reads of every worker thread in the process; Moro sets 64 itself but only at `listen()`,
  after its startup has initialised the pool at Node's default of 4, and Node reads the variable
  only at process start.
- `json-tls`, `static-tls` and `8gbit` listen on `8081` behind the engine's own TLS listener
  (TLS 1.3, ALPN `http/1.1`), when `/certs/server.crt` and `/certs/server.key` are mounted. Moro
  locks one configuration per process, so that listener is a second process running the same file
  with `MORO_ROLE=tls`, clustered the same way; it is not started when the certificates are absent.
- `tls_check` is opted into: a third process of the same file (`MORO_ROLE=tlscheck`) listens on
  `9000` reading `/certs-tls`, with `server.ssl.watch: true`, so a pair replaced on disk is
  validated and swapped onto the running listener without a restart and without touching
  connections already established. Only started when `/certs-tls` is mounted, which validate.sh
  alone does.
- `/echo` sends back `req.rawBody`, the framework's undecoded copy of the request body, so the
  bytes are the bytes that arrived, `Content-Length` or chunked alike.
- `/ws` is the engine's own RFC 6455 support through `app.websocket()` with `{ raw: true }`, so a
  text frame reaches the handler as the string it carried and `socket.send()` returns it as one.
- Static files go through `staticFiles({ root: '/data/static', precompressed: true })`, which
  stats and reads the file on every request, so a replaced file is served on the next response,
  and serves the `.br` or `.gz` sidecar on disk when the client accepts it. It is mounted on the
  TLS listener behind a path check so the JSON route on that port does not pay for the lookup.
- `fortunes` goes through EJS directly: Moro ships no view layer, so the template is rendered by
  the engine's own `renderFile`, a separate file with `<%= %>` escaping every cell.
- The gateway and production-stack edges are stock nginx and Caddy, configured as the fulmine
  entry configures them: `/static/*` off disk at the edge, everything else forwarded over
  loopback h1 with a keepalive pool, and `/api/*` past the shared JWT verifier first.
- The production-stack cache-aside goes through the framework's cache adapters:
  `RedisCacheAdapter` on the stack's `REDIS_URL`, one connection per worker so an update on any
  worker invalidates what every other one reads, and `MemoryCacheAdapter` otherwise. Items live
  for at most a second, users for thirty.
