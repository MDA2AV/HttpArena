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
| `/echo` | POST | Returns the request body back verbatim |
| `limited-conn` | `GET /baseline11` | short-lived connections |
| `json` | `GET /json/{count}?m=M` | single-allocation response, precomputed item prefixes |
| `json-comp` | `GET /json/...` + `Accept-Encoding` | gzip-compressed response |
| `static` | `GET /static/<file>` | assets preloaded into memory, MIME by extension, 404 on miss |
| `async-db` | `GET /async-db?min&max&limit` | `db.pg` ConnectionPool |
| `crud` | `GET/POST/PUT /crud/items[/id]` | list + read + create + update; in-memory cache-aside (`X-Cache` MISS/HIT, invalidated on update — no Redis) |
| `fortunes` | `GET /fortunes` | DB rows + runtime row, HTML-escaped |
| `baseline-h2c`, `json-h2c` | `GET /baseline2`, `GET /json/{count}` over h2c on `:8082` | HTTP/2 prior knowledge only (an HTTP/1.1 request gets `505`): the `PRI *` preface hands the connection to vanilla's `http2` module (`core.queue_takeover`), which surfaces each request once complete |
| `unary-grpc` | `POST /benchmark.BenchmarkService/GetSum` over h2c on `:8080` | same takeover from the `PRI *` preface; HEADERS, the `SumReply` as DATA, then `grpc-status: 0` as trailers |
| `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited` | `GET /ws` (WebSocket) | RFC 6455 upgrade, then the connection is handed to a frame handler (`core.queue_takeover`): text/binary echoed, ping → pong, close handshake; a pipelined burst is answered in one write |

## Stack

* [V](https://vlang.io) 0.5.1 (pinned prebuilt release)
* [vanilla](https://github.com/enghitalo/vanilla) — raw epoll HTTP server
* `db.pg`, `json`, `compress.gzip` (stdlib)

## Environment

* `DATABASE_URL`, `DATABASE_MAX_CONN` — Postgres connection + pool size
* `DATASET_PATH` (default `/data/dataset.json`), `STATIC_DIR` (default `/data/static`)

> TLS-terminated HTTP/2 (`baseline-h2`, `static-h2`, `unary-grpc-tls`) and HTTP/3
> need protocol support vanilla doesn't have yet: its TLS layer advertises only
> `http/1.1` via ALPN ([enghitalo/vanilla#142](https://github.com/enghitalo/vanilla/issues/142)).
