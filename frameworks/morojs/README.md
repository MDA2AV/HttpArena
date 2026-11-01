# morojs

MoroJS on its native HTTP engine, clustered by the framework itself.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [MoroJS 1.8](https://github.com/Moro-JS/moro) on `@morojs/engine` 1.1.16, its own native HTTP engine
- **Build:** Multi-stage on `node:26-trixie-slim`; the engine ships prebuilt binaries, so no toolchain

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values (behind the gateway proxies) |
| `/delay/:ms` | GET | Answers `ms` from a timer callback `ms` milliseconds later |
| `/json/:count` | GET | Serializes a slice of the dataset, brotli (quality 3) or gzip (level 3) when the client asks for it |
| `/echo` | POST | Returns the request body back verbatim (TLS listener) |
| `/ws` | WebSocket | Echoes every text and binary frame unchanged |
| `/async-db` | GET | Reads from PostgreSQL through `pg`, prepared statement, pool sized under `DATABASE_MAX_CONN` (240 at most), the driver's callback answering the request |
| `/fortunes` | GET | Reads the fortune rows from PostgreSQL, appends the runtime row, sorts and renders `views/fortunes.ejs`, compiled once per worker |
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
  leaves the body alone when the header is absent. brotli at quality 3 is preferred, through the
  middleware's `encodings` and `brotli` options, with the encoder's window fitted to the body by
  the framework: the profile scores bytes squared against rate, and measured on the board gzip at
  level 3 ran 7% more requests than brotli 3 but sent 10% more bytes per reply, a 9% lower score.
  gzip at level 3 remains available to a client that accepts nothing else. The middleware keeps one
  encoder per setting per worker and resets it between bodies (`reuseEncoders`, the default): on the
  Node 26 the image ships, brotli's reset keeps its quality, so a reply costs the compression alone
  and not an encoder built and torn down around it (measured on these bodies: 30 us against 45 or
  more per body).
- The proxied stacks (`compose.gateway.yml`, `compose.gateway-h3.yml`, `compose.production-stack.yml`)
  run the server with `MORO_ENGINE_SERVE_ORDER=auto`: the engine's epoll transport serves a loop
  turn's sockets grouped by the CPU their peer sends from, an order its design notes measured to lose
  about a quarter at 256 connections against arrival order when every request enters JavaScript under
  a peer that oversubscribes its cores, which is what an edge proxy is. `auto` has each loop measure
  both orders and keep the faster one. The standalone container keeps the engine's default.
- `server.backlog: 16384`: the edges in front of the gateway and production-stack profiles keep an
  idle pool of 2048 upstream connections under tens of thousands of requests in flight, so they
  dial and drop thousands of connections per wave. At the engine's default backlog of 512 a wave
  overflows a worker's accept queue, the kernel drops the SYN and the proxy retries it a second
  later, which was those profiles' tail latency. Measured on a 4096-dialer churn: p99 1019 ms at
  512, 52 ms at 4096, same throughput. The harness raises `somaxconn` to 65535 for this.
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
- `baseline-h2`, `static-h2`, `baseline-h2c` and `json-h2c` run on Moro's HTTP/2 server, which is
  Node's http2 module behind the framework's own request and response objects (`engine: 'node'`
  with `http2: true`); the native engine speaks HTTP/1.1 only. `:8443` terminates TLS with ALPN
  `h2` (HTTP/1.1 still accepted), `:8082` is cleartext prior-knowledge HTTP/2. Each is its own
  process for the same one-configuration-per-process reason, clustered as node:cluster processes,
  which is Moro's transport for its Node servers.
- `/echo` sends back `req.rawBody`, the framework's undecoded copy of the request body, so the
  bytes are the bytes that arrived, `Content-Length` or chunked alike; a Buffer handed to
  `res.send()` goes out `application/octet-stream` through the framework's prepared reply.
- `/ws` is the engine's own RFC 6455 support through `app.websocket()` with `{ raw: true }`, so a
  text frame reaches the handler as the string it carried and `socket.send()` returns it as one.
  The engine corks the connection for the duration of each read (`@morojs/engine` 1.1.14), so
  the echoes of a pipelined batch of frames leave in one write, each frame built straight into
  that write (1.1.15). The upgrade itself is the engine's as well (1.1.15, MoroJS 1.8.17): a valid
  handshake is answered and the socket opened without the request ever entering JavaScript, and
  the handshake's headers, query and peer address stay readable on the socket on demand.
- Static files go through `staticFiles({ root: '/data/static', precompressed: true, cache: true })`:
  the framework's handler with its in-memory cache. A file and its `.br` and `.gz` sidecars are
  read once and served from memory with their `ETag` and `Last-Modified`, the sidecar negotiated
  per request from `Accept-Encoding`. The disk is stat'ed again at most once a second, and as soon
  as the directory reports a change, so a replaced file (same length or not) is served promptly.
  Without the cache the handler resolves, stats and reads the file and its sidecars on every
  request, each a libuv threadpool round trip shared by every worker thread of the process. It is
  mounted on the TLS listener behind a path check so the JSON route on that port does not pay for
  the lookup; the check calls `next()` synchronously, which keeps that route on the server's
  synchronous dispatch.
- `fortunes` goes through EJS directly: Moro ships no view layer, so the template file is compiled
  once per worker with `ejs.compile` and rendered per request, `<%= %>` escaping every cell.
- `/async-db` and `/fortunes` answer from the driver's callback rather than from an async handler:
  the reply is the same, and the request stops paying three promise hops (the handler's, the
  router's, the server's). `pg-native`, which the uWebSockets-based entries use, loads its libpq
  addon once per process and refuses the second worker thread, so it cannot serve a thread cluster.
- The gateway and production-stack edges are stock nginx and Caddy, configured as the fulmine
  entry configures them: `/static/*` off disk at the edge, everything else forwarded over
  loopback h1 with a keepalive pool, and `/api/*` past the shared JWT verifier first.
- The production-stack cache-aside goes through the framework's cache adapters:
  `RedisCacheAdapter` on the stack's `REDIS_URL`, one connection per worker so an update on any
  worker invalidates what every other one reads, and `MemoryCacheAdapter` otherwise. Items live
  for at most a second, users for thirty.
