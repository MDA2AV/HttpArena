# vanilla-epoll

[vanilla](https://github.com/enghitalo/vanilla) is a minimalist, high-performance
HTTP server written in [V](https://vlang.io) — multi-threaded, non-blocking,
lock-free, copy-free, with `SO_REUSEPORT`. This entry runs the **epoll** I/O
backend (`io_multiplexing: .epoll`); see `vanilla-io_uring` for the io_uring
backend.

## Implemented profiles

| Profile | Endpoint | Notes |
|---|---|---|
| `baseline` | `GET/POST /baseline11` | `a + b` (+ body on POST); handles chunked + TCP-fragmented requests |
| `pipelined` | `GET /pipeline` | returns `ok` |
| `upload` | `POST /upload` | returns body byte count (up to 20+ MiB via `max_request_bytes`) |
| `limited-conn` | `GET /baseline11` | short-lived connections |
| `json` | `GET /json/{count}?m=M` | single-allocation response, precomputed item prefixes |
| `json-comp` | `GET /json/...` + `Accept-Encoding` | gzip-compressed response |
| `static` | `GET /static/<file>` | assets preloaded into memory, MIME by extension, 404 on miss |
| `async-db` | `GET /async-db?min&max&limit` | `db.pg` ConnectionPool |
| `crud` | `GET/POST/PUT /crud/items[/id]` | list + read + create + update; in-memory cache-aside (`X-Cache` MISS/HIT, invalidated on update — no Redis) |
| `fortunes` | `GET /fortunes` | DB rows + runtime row, HTML-escaped |
| `api-4`, `api-16` | mixed baseline + json + async-db | |

## Stack

* [V](https://vlang.io) 0.5.1 (pinned prebuilt release)
* [vanilla](https://github.com/enghitalo/vanilla) — raw epoll HTTP server
* `db.pg`, `json`, `compress.gzip` (stdlib)

## Environment

* `DATABASE_URL`, `DATABASE_MAX_CONN` — Postgres connection + pool size
* `DATASET_PATH` (default `/data/dataset.json`), `STATIC_DIR` (default `/data/static`)

> HTTP/2, HTTP/3 and gRPC profiles need protocol support vanilla doesn't have
> yet — tracked in [enghitalo/vanilla#18](https://github.com/enghitalo/vanilla/issues/18).
