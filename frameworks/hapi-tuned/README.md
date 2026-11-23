# hapi-tuned

The [`hapi`](../hapi/) entry with three things changed. Routes, query and payload
parsing and JSON serialization are that entry's, unchanged.

## Stack

- **Language:** Node 26
- **Framework:** hapi 21 (`@hapi/hapi`), no plugins
- **Build:** `node:26-trixie-slim`

## What is tuned

- **Workers bind with `reusePort`.** The entry creates the `http`/`https` listener and
  hands it to hapi (`listener`, `autoListen: false`), then binds it with `reusePort: true`.
  Each worker has its own accept queue and the kernel spreads connections over them. The
  standard entry leaves it to the cluster module, whose primary accepts every connection
  and passes it to a worker - one process in front of all the others when connections are
  short-lived.
- **Brotli is one synchronous call, at quality 1.** The encoder registered with
  `server.encoder('br', ...)` collects the serialized payload and codes it with
  `zlib.brotliCompressSync`. The standard entry registers Node's brotli stream at quality 3,
  and a stream sends every write, flush and close through the libuv thread pool. hapi's
  compression still negotiates the encoding and calls the encoder; the body is serialized
  and compressed per request.
- **Unused request work is off.** `routes.state.parse: false` (no cookies),
  `routes.response.ranges: false` (no range requests) and `operations.cleanStop: false`
  (no connection tracking for graceful stop).

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/delay/{ms}` | GET | Waits `ms` milliseconds, returns `ms` |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Port 8081 is a second hapi server on an `https` listener, registering the same route plugin
- One cluster worker per available core; cluster only forks them, it does not share the port
