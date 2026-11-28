# morojs

MoroJS on its native HTTP engine, clustered by the framework itself.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [MoroJS 1.9](https://github.com/Moro-JS/moro) on `@morojs/engine` 1.2, its own native HTTP engine
- **Build:** Multi-stage on `node:26.13-trixie-slim`; the engine ships prebuilt binaries, so no toolchain

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/delay/:ms` | GET | Answers `ms` milliseconds later |
| `/json/:count` | GET | Serializes a slice of the dataset, brotli or gzip when the client accepts one |
| `/echo` | POST | Returns the request body back verbatim |
| `/ws` | WebSocket | Echoes every text and binary frame |
| `/async-db` | GET | Reads from PostgreSQL through a `pg` pool |
| `/fortunes` | GET | Reads the fortune rows, appends the runtime row, sorts and renders an EJS template |
| `/static/:filename` | GET | Serves a file through the framework's `staticFiles` middleware |
| `/public/*`, `/api/items/:id`, `/api/me` | GET/POST | The production-stack routes, with a cache-aside on the framework's cache adapters |
| `/spec`, `/spec/headers` | GET/HEAD/OPTIONS/POST | The compliance routes |
| `/parse` | POST | The body parsed by its media type (resilience suite) |

## Notes

- Standard mode: `createApp()` with its defaults on the native engine. Request tracking and request
  logging are turned off through their documented options.
- Clustering is Moro's own (`performance.clustering`): one worker thread per core, each binding the
  port through `SO_REUSEPORT`. The count is passed in from the cgroup quota, because `auto` counts
  every host core under `--cpuset-cpus`.
- One process serves every listener, an app per listener on the same worker threads: `8080`
  HTTP/1.1, `8081` HTTP/1.1 over TLS, `8443` HTTP/2 over TLS, `8082` cleartext HTTP/2, and `9000`
  for `tls_check` (`server.ssl.watch: true`). The TLS listeners start only when their certificates
  are mounted.
- `json-comp` is the framework's `compression()` middleware on the `/json` route alone: brotli at
  quality 3 preferred, gzip at level 3 otherwise.
- Static files are `staticFiles({ root: '/data/static', precompressed: true, cache: true })`.
- `server.backlog: 16384`, for the connection churn of the gateway and production-stack edges, and
  `UV_THREADPOOL_SIZE=64` in the Dockerfile, since Node reads it only at process start.
- `/async-db` and `/fortunes` answer from the `pg` callback. Moro ships no view layer, so the
  fortunes template is compiled once per worker with `ejs.compile`.
- The gateway and production-stack edges are stock nginx (`nginx:1.27-alpine`), with a QUIC listen
  for `gateway-h3`. The cache-aside uses `RedisCacheAdapter` on `REDIS_URL` and `MemoryCacheAdapter`
  without it.
- The connection, compliance and resilience suites run on the framework's defaults; nothing is set
  for them here.
