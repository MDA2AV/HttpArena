# veb

[veb](https://modules.vlang.io/veb.html) is the web framework that ships with
the [V](https://vlang.io) standard library. It now runs on the **parallel
`fasthttp` backend** (multi-threaded, `SO_REUSEPORT` epoll, zero-copy append
handler), whose request framing reassembles TCP-fragmented requests and decodes
chunked bodies — which is what lets veb subscribe to the `baseline` profile
(the old single-threaded backend could not decode chunked requests).

## Implemented tests

| Test | Endpoint |
|------|----------|
| `baseline` / `limited-conn` | `GET/POST /baseline11?a&b` (chunked + fragmentation handled by the backend) |
| `pipelined` | `GET /pipeline` |
| `json` | `GET /json/{count}?m=M` over `/data/dataset.json` |
| `json-comp` | `GET /json/{count}?m=M` + `Accept-Encoding: gzip` → gzipped (process-shared cache) |
| `upload` | `POST /upload` → received byte count |
| `static` | `GET /static/*` via veb's static handler (mounted from `/data/static`), 404 for misses |
| `async-db` | `GET /async-db?min&max&limit` via `db.pg` |
| `crud` | `GET/POST /crud/items`, `GET/PUT /crud/items/{id}` (in-memory cache-aside, `X-Cache` MISS/HIT) |
| `fortunes` | `GET /fortunes` (DB rows + a runtime row, HTML-escaped) |

`json-tls` is **not** subscribed: it requires a second TLS listener on `:8081`
(veb's separate OpenSSL SSL path), which is not wired up here.

The mutable crud and gzip caches live on the shared `App` (one instance across
all workers, so the `X-Cache` MISS→HIT probe survives `SO_REUSEPORT` routing the
two requests to different worker threads) and are `RwMutex`-guarded.

## Stack

* [V](https://vlang.io) — pinned master commit `84a76d791`, the
  `fasthttp: refactor toward the vanilla architecture` commit
  ([vlang/v#27771](https://github.com/vlang/v/pull/27771)); veb runs on the
  parallel `fasthttp` backend it introduced
* [veb](https://modules.vlang.io/veb.html) — HTTP framework, built with the
  default GC (Boehm; `-prealloc` is a never-free arena unsuited to a server)
* `db.pg` (stdlib) — pooled Go-style PostgreSQL driver (`db.exec_param_many`)

JSON is serialized manually (precomputed prefixes + `strings.Builder`) to avoid
per-request reflection.
