# Plod

[Plod](https://github.com/kaitk/plod) is a REST framework for
[Goose](https://github.com/aardappel/goose), a memory-safe systems language with no heap
allocator, garbage collector, or lifetime annotations. Plod has routes, scopes,
middleware, and extractors in the manner of Actix, and builds on
[goose-http](https://github.com/kaitk/goose-http), its HTTP engine: HTTP/1.1, h2, TLS,
and WebSocket over an io_uring loop per worker.

The entry is `app.goose`, an application written as one on Plod is, and two root files
that declare the packages and serve it. The Dockerfile builds both with Goose's
`v2026.3` release, downloaded and checked against its SHA-256, or built from that tag
on arm64, which the release has no archive for.

| Package | Tag | What for |
|---|---|---|
| [Plod](https://github.com/kaitk/plod) | `v0.5.6` | The framework, with `plod::try_reply`, `plod::bytes`, and `plod::field` |
| [goose-http](https://github.com/kaitk/goose-http) | `v0.5.9` | HTTP/1.1, h2, WebSocket, the loop, and mail between threads |
| [goose-compress](https://github.com/kaitk/goose-compress) | `v0.1.4` | gzip, deflate, and zstd |
| [goose-tls](https://github.com/kaitk/goose-tls) | `v0.0.5` | A TLS 1.3 server in Goose, over OpenSSL's libcrypto for the ciphers and keys |
| [goose-hash](https://github.com/kaitk/goose-hash) | `v0.0.4` | SHA-1 for the WebSocket handshake, SHA-256 for SCRAM |
| [goose-postgres](https://github.com/kaitk/goose-postgres) | `v0.0.6` | Goose's Postgres driver: the protocol, an async pool per worker, and a blocking connection |

## Listeners

- 8080: HTTP/1.1.
- 8082: h2 with prior knowledge (h2c).
- 8081 and 8443, where HttpArena mounts `/certs`: TLS 1.3, HTTP/1.1 on 8081, and h2 or
  HTTP/1.1 by ALPN on 8443.
- 8085, under the compose files only (`PROXY_PORT`): HTTP/1.1 for the proxy.

The image holds two binaries: `server`, without TLS, and `server-tls`, which adds 8081
and 8443 with goose-tls's server, its handshake and records in Goose and its ciphers
from libcrypto. It starts `server-tls` where `/certs` holds the certificate and key,
and `server` otherwise. `benchmark.sh` mounts `/certs` for every profile, so there
`server-tls` serves them all; `validate.sh` mounts it only for the profiles that use
TLS, and the compose files not at all.

Under compose, the server gets no `/certs`, so 8443 is the proxy's. It still opens 8080,
where `benchmark.sh`'s readiness probe looks for every compose profile, as libuvcpp's
`H1_PROBE_PORT` does, and 8082 with it, which no profile there uses. During
`validate.sh`, the entry's own container holds 8080 and 8082, and the compose server
shares them through `SO_REUSEPORT`; the proxies reach it on 8085, which nothing else
holds.

## Profiles

| Profiles | How they're served |
|---|---|
| baseline, pipelined, limited-conn, latency-1m, latency-10k, latency-500k-8cpu | `/baseline11` from `plod::query_int` and `plod::body`; `/pipeline` with `plod::text` |
| async | `/delay/:ms` with `plod::pause`, which answers from the worker's timer |
| json-comp, json-tls, json-h2c | `/json/:count` serialized per request with `plod::format_fields`, inside `plod::compressed` |
| 8gbit | `POST /echo` over TLS, the body sent back with `plod::bytes` |
| static-tls, static-h2 | `/static/*name` from disk through `plod::files`, which sends a `.br` or `.gz` sibling where `Accept-Encoding` takes it |
| baseline-h2, baseline-h2c | `/baseline2`, over goose-http's h2 |
| async-db | `/async-db` on goose-postgres's async pool, the rows decoded into a struct and serialized with `plod::format_fields` |
| echo-ws, echo-ws-pipeline, echo-ws-limited | `/ws` with `plod::ws_upgrade` and `plod::ws_read` |
| gateway-64 | Stock nginx (`proxy/`) terminating TLS and h2, serving `/static/` from disk, and proxying the rest over HTTP/1.1 |
| gateway-h3 | Stock nginx (`proxy-h3/`), as gateway-64, with the image's HTTP/3 on 8443 over UDP beside h2 |
| production-stack | Stock nginx (`proxy-production/`) with HttpArena's authsvc on `/api/`; the server's cache-aside below |

production-stack's cache is in process, which the profile allows, as tako's and
libuvcpp's are. It holds each item's and user's row, decoded, for 1 and 30 seconds, and
the worker serializes it per request. Lanes of one thread each, as many as the workers
within half of `DATABASE_MAX_CONN`, own the ids sent to them and a blocking Postgres connection, so a write and the reads
after it meet one cache. `POST /api/items/:id` updates the row and drops it from its
lane's cache. The Redis the profile requires runs, and the server waits for it to be
healthy, but doesn't use it.

The cache's dictionaries don't evict: an entry past its time is fetched again, and its
slot reused, but every id fetched keeps one. The dataset's ids bound them here. A cache
over keys without such a bound needs a capacity and eviction.

## Settings

Each is documented configuration, set as the documentation says, not tuning.

- Workers: goose-http's default, one per CPU of the container's cpuset
  ([`http::worker_count`](https://github.com/kaitk/goose-http/blob/v0.5.9/docs/api.md#config-and-shutdown)).
- `mail_slots` and `max_waiting` turn waiting on, and are 0 by default
  ([answers that wait](https://github.com/kaitk/goose-http/blob/v0.5.9/docs/api.md#answers-that-wait)):
  `/delay` and `/async-db` need them. `max_waiting` is a worker's connection limit,
  `max_conns`: one wait per connection.
- production-stack's cache follows Plod's production guidance for lanes that every
  worker asks
  ([sizing a lane's admissions and boxes](https://github.com/kaitk/plod/blob/v0.5.6/docs/best-practices/lanes.md#67-sizing-a-lanes-admissions-and-boxes)).
  A worker admits at most 1,024 asks to the lanes at once, less its Postgres pool's
  hand-overs: 1,015 at 24 workers (`admission` in `app.goose`).
  The profile's load keeps about 16,000 requests in flight at the edge, 1,024 h2
  connections of 16 streams, which reach the server as one request per upstream
  connection: up to about 400 cache asks a worker at 24 workers. It answers one past
  them with 503 `busy`, and one a full lane box refuses with 503 `unavailable`, at
  once, and doesn't retry. The boxes and waits are sized from that count: each lane's
  box holds 1,024 jobs, its share of every worker's admissions; each worker's box 1,024
  replies, its admitted asks and its pool's hand-overs; and `max_waiting` is the
  admission, so production-stack's waits are its admitted asks. At 24 workers the boxes
  take 19 MiB. A reply is one message
  of 512 bytes. The lanes reply with `plod::try_reply`, which drops a reply that finds
  a worker's box full, and the ask then times out with 504, rather than hold up every
  other worker's jobs.
- The Postgres pools are sized from `DATABASE_MAX_CONN`, less one connection left for
  another client, as go-stdlib, chi, echo, and gin leave headroom: an even share for
  each worker's pool, and in production-stack at most half for the lanes.
- `API_CACHE`, set only in `compose.production-stack.yml`, opens the lanes.
- Compression is `plod::compressed`'s defaults: the coding `Accept-Encoding` weighs
  highest, at goose-http's default levels, for bodies from goose-http's default 256
  bytes.
- The C that Goose writes is compiled with `-O3 -march=native`, for the machine that
  builds the image, as actix, userver, and Aegon build theirs. Goose's documentation
  names no flags, and `goose build` takes none, so the Dockerfile passes `--cc` a gcc
  wrapper that adds them.

## Completeness

- Routing: `plod::routes`, `plod::scope`, and path parameters such as `/json/:count`
  and `/static/*name` route every request.
- Middleware: `plod::compressed` wraps the JSON routes, and Plod answers a route's
  failures, refusals, and timeouts.
- Request: extractors read the query (`plod::query_int`), the path
  (`plod::param_int`), headers (`plod::header`), and a JSON body into a struct
  (`plod::take`).
- Response: `plod::json` serializes a struct, through Goose's standard `json` writer,
  with a field of the route's own where its block adds one (`X-Cache`);
  `plod::text`, `plod::empty`, and `plod::bytes` answer plain; and `plod::files`
  serves files.
