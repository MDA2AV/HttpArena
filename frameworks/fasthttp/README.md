# fasthttp

A raw multi-threaded [V](https://vlang.io) HTTP server built on the `fasthttp`
module from V's standard library (epoll, non-blocking, `SO_REUSEPORT`, one
worker per core).

It uses the module's **append handler** (`AppendHandler`): each handler writes
the complete raw HTTP response straight into the connection's reused write
buffer — no per-request response object, no copy — and the reactor flushes the
whole pipelined burst in one `send`. Per-worker scratch buffers come from the
lock-free `make_state` hook; shared read-only data and the mutex-guarded caches
live in `user_data`.

## Implemented tests

| Test | Endpoint |
|------|----------|
| `baseline` / `limited-conn` | `GET/POST /baseline11?a&b` (handles chunked; the reactor reassembles TCP-fragmented requests) |
| `pipelined` | `GET /pipeline` |
| `json` | `GET /json/{count}?m=M` over `/data/dataset.json` |
| `json-comp` | `GET /json/{count}?m=M` + `Accept-Encoding: gzip` → gzipped (process-shared cache) |
| `upload` | `POST /upload` → received byte count |
| `static` | `GET /static/*` → `sendfile(2)` from a preloaded MIME/size table, 404 for misses |
| `async-db` | `GET /async-db?min&max&limit` via `db.pg` |
| `crud` | `GET/POST /crud/items`, `GET/PUT /crud/items/{id}` (in-memory cache-aside, `X-Cache` MISS/HIT) |
| `fortunes` | `GET /fortunes` (DB rows + a runtime row, HTML-escaped) |

`json-tls` is **not** subscribed: the stdlib `fasthttp` server has no TLS
backend. `async-db`, `crud` and `fortunes` issue blocking `db.pg` queries on the
worker thread — `fasthttp` has no async watch reactor yet, so a query parks that
worker's epoll loop for its duration (the `.suspend` step currently drops the
connection, so it is not used).

## Stack

* [V](https://vlang.io) — pinned master commit `84a76d791`, the
  `fasthttp: refactor toward the vanilla architecture` commit
  ([vlang/v#27771](https://github.com/vlang/v/pull/27771)): append handler,
  `make_state`, request framing (fragmented + chunked reassembly), `sendfile`
* [fasthttp](https://modules.vlang.io/fasthttp.html) — epoll HTTP server, built
  with the default GC (Boehm; `-prealloc` is a never-free arena unsuited to a
  long-running server)
* `db.pg` (stdlib) — pooled Go-style PostgreSQL driver (`db.exec_param_many`)

JSON responses are built in a single allocation (precomputed prefixes written
directly into the connection buffer) with no per-request reflection.
