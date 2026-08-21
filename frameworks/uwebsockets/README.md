# uWebSockets.js

uWebSockets.js, the Node binding of the uWebSockets C++ server.

## Stack

- **Language:** Node 24
- **Framework:** uWebSockets.js 20.69
- **Build:** `node:24-trixie-slim`
- **Database:** `pg` with the `pg-native` libpq bindings
- **Cache:** the harness Redis sidecar when `REDIS_URL` is set, otherwise an in-process map

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |
| `/static/{file}` | GET | Serves a fixture file, read from disk on every request |
| `/async-db` | GET | Range query over `items`, `rating` nested in the response |
| `/crud/items` | GET | Paginated list by category |
| `/crud/items/{id}` | GET | Single read, cache-aside with `X-Cache: HIT`/`MISS` |
| `/crud/items` | POST | Create (upsert on id conflict) |
| `/crud/items/{id}` | PUT | Update, invalidates the cached entry |

TLS on `:8081` serves `/json/{count}` and `/static/{file}` for the `json-tls` and
`static-tls` profiles, through uWS's own `SSLApp`.

## Notes

- Routing, query and body handling through the uWS `App` API. There is no router,
  middleware stack, body parser or static handler in uWS, so each of these is
  written against the documented primitives rather than a framework abstraction.
- JSON serialized per request with `JSON.stringify`.
- uWebSockets.js ships no compression middleware, so `json-comp` gzips the body
  with the Node zlib bindings when the request asks for it.
- **Static files are served uncompressed.** The standard rules allow pre-compressed
  `.br`/`.gz` variants only through a documented framework API and bar custom
  file-suffix lookup logic; uWS has neither a static handler nor compression
  middleware, so there is no compliant way to negotiate them here. Compression is
  optional for that profile.
- Static files are read from disk on every request with `fs.readFile` — nothing is
  preloaded, memory-mapped or held between requests. Read whole rather than streamed:
  uWS documents a `tryEnd`/`onWritable` streaming pattern in `examples/VideoStreamer.js`,
  but that exists for a multi-GB video, and at these file sizes the per-request
  ReadStream setup costs about half the throughput (measured: 180k vs 92k rps at 1024c).
- Postgres pool sized from `DATABASE_MAX_CONN` and divided by the worker count, since
  this entry runs one process per core.
- `crud` reads use a 200 ms absolute TTL invalidated on PUT, through the Redis sidecar
  the profile allows for one-process-per-core runtimes.
- One cluster worker per available core, listening on the same port as the
  uWebSockets clustering example does.
