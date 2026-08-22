# bun

Bun's own HTTP server, `Bun.serve`, with no framework on top. One process per CPU, all sharing
port 8080 through `reusePort`.

## Stack

- **Language:** TypeScript
- **Runtime:** [Bun](https://github.com/oven-sh/bun) 1.3
- **Framework:** none, `Bun.serve` from the standard library
- **Build:** Single stage on `oven/bun:1.3.14`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/json/:count` | GET | Serializes a slice of the dataset, gzipped when the client accepts it |
| `/upload` | POST | Counts the bytes of the request body |
| `/static/:file` | GET | Serves one of the 20 files from `/data/static`, read off disk per request |
| `/async-db` | GET | Postgres range query over `items`, `min`/`max`/`limit` |
| `/crud/items` | GET/POST | Paginated list by category; POST upserts |
| `/crud/items/:id` | GET/PUT | Cache-aside read through Redis; PUT updates and invalidates |
| `/fortunes` | GET | Postgres rows plus one runtime row, sorted, HTML-escaped into a table |

The same `/json/:count` and `/static/:file` routes are also served over TLS on port 8081 for the
`json-tls` and `static-tls` profiles, when the harness mounts `/certs`.

## Notes

- Postgres and Redis are `Bun.SQL` and `Bun.RedisClient`, both shipped with the runtime, so the
  database profiles cost this entry no dependency.

- Bun was on the board as a WebSocket echo server only. This entry is the plain HTTP floor of the
  runtime itself, so a Bun framework entry can be read against it.
- Scaling is not the cluster module: every process calls `Bun.serve` with `reusePort`, binds the
  same port and lets the kernel spread the accepts. The process count comes from `nproc`, lowered
  to the cgroup quota when there is one.
- Routing is a handful of string comparisons on the path taken out of `req.url`, since with no
  framework there is no router to measure.
- `Bun.serve` does no content negotiation, so `/json` gzips its own body when `Accept-Encoding`
  asks for it, and sends it uncompressed otherwise.
- `/upload` counts the body chunk by chunk instead of buffering it, which keeps 20 MB requests on
  hundreds of connections out of memory.
