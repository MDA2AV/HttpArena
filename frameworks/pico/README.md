# pico

A raw [V](https://vlang.io) server built on the `picoev` non-blocking event loop
and the `picohttpparser` HTTP parser (both in the V standard library). One
process per core shares the listen socket via `SO_REUSEPORT`.

## Implemented tests

| Test | Endpoint |
|------|----------|
| `baseline` | `GET/POST /baseline11` (handles chunked) |
| `pipelined` | `GET /pipeline` |
| `json` | `GET /json/{count}?m=M` over `/data/dataset.json` |

## Stack

* [V](https://vlang.io) — pinned master commit `c0624b274` (built from source), default GC
* [picoev](https://modules.vlang.io/picoev.html) + [picohttpparser](https://modules.vlang.io/picohttpparser.html)

JSON is serialized manually (precomputed prefixes + `strings.Builder`), no
per-request reflection.

> DB profiles (`async-db`) are not subscribed: picoev is a single-threaded
> event loop and the stdlib `db.pg` driver is blocking, so a query would stall
> the loop. A non-blocking PG path would be needed to add them.
