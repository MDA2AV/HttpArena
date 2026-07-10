# fasthttp

A raw multi-threaded [V](https://vlang.io) HTTP server built on the `fasthttp`
module from V's standard library (epoll, non-blocking, `SO_REUSEPORT`).

## Implemented tests

| Test | Endpoint | Notes |
|------|----------|-------|
| `pipelined` | `GET /pipeline` | Precomputed constant response |
| `upload` | `POST /upload` | Returns body byte count |
| `json` | `GET /json/{count}?m=M` | Precomputed prefixes, single allocation |
| `json-comp` | `GET /json/{count}?m=M` (gzip) | Lazy per-(count,m) gzip cache |
| `async-db` | `GET /async-db?min&max&limit` | `db.pg` pooled driver |
| `fortunes` | `GET /fortunes` | DB rows + runtime row, HTML-escaped, sorted |
| `static` | `GET /static/*` | Preloaded into memory, correct MIME types |
| `crud` | `GET/POST /crud/items`, `GET/PUT /crud/items/:id` | In-memory cache slab, X-Cache MISS/HIT |

> **baseline** is not subscribed: the fasthttp server parses each `recv()` in one
> shot and does not reassemble TCP-fragmented requests, which the baseline
> validation requires.

## Stack

* [V](https://vlang.io) — pinned master commit `cef604a26` (built from source)
* [fasthttp](https://modules.vlang.io/fasthttp.html) — epoll HTTP server, built
  with the default GC (Boehm; `-prealloc` is a never-free arena unsuited to a server)
* `db.pg` (stdlib) — pooled Go-style PostgreSQL driver (`db.exec_param_many`)
* `compress.gzip` (stdlib) — gzip compression for `json-comp`
* `sync.RwMutex` — guards the shared CRUD slab cache and gzip response cache

## Design notes

- **JSON** responses are built with zero-alloc write helpers (`ws`/`wb`/`wi`) writing
  directly into a pre-sized `[]u8` — no `strings.Builder` intermediate and no per-request
  reflection.
- **CRUD cache** is an id-indexed slab (`crud_cache_slots = 50001`) so slots are reused
  in-place across re-caches — no orphaned allocations under Boehm GC. A `PUT` flips
  `valid = false` and keeps the buffer for the next MISS to refill, satisfying the
  MISS → HIT → MISS-after-PUT contract.
- **gzip cache** is lazy: only the `(count, m)` pairs actually sent by the benchmark
  profile are compressed. Precomputing the full grid wasted ~135 MiB at startup.
- **Static files** are preloaded once at startup from `$STATIC_DIR` (`/data/static`)
  into a `map[string]StaticFile`. No sendfile(2) — fasthttp does not expose a
  `queue_file` API, so the preloaded bytes are copied into the response buffer.
