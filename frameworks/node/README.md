# node

Node's own HTTP server, `node:http`, with no framework on top and no dependencies at all.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** none, `http.createServer` from the standard library
- **Build:** Single stage on `node:26-trixie-slim`

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

- The only dependencies are `pg` and `ioredis`. node ships neither a Postgres nor a Redis client,
  and the database profiles cannot run without them. Nothing else is on top: still no framework and
  still no router.

- Node was on the board only through frameworks. This entry is the plain HTTP floor of the
  runtime itself, so express, fastify, koa, nestjs and the two h3 entries can be read against it.
- `node:cluster` forks one worker per core, but the round robin of the cluster primary is not in
  the path: each worker binds 8080 itself with `reusePort`, so the kernel spreads the accepts the
  same way bun and deno do. node sets `exclusive` on its own when `reusePort` is true, which is
  what takes the cluster listen path out. The other node entries here still use the round robin.
- Routing is a handful of string comparisons on `req.url`, and the query is parsed by hand, since
  with no framework there is no router and no parser to measure.
- `node:http` negotiates nothing, so `/json` gzips its own body with `zlib` when `Accept-Encoding`
  asks for it, at the default level, and sends it uncompressed otherwise.
- `/upload` counts the body chunk by chunk instead of buffering it, which keeps 20 MB requests on
  hundreds of connections out of memory.
- The dataset is read once per worker at startup. A missing file leaves an empty list, since the
  profiles other than json run without the mount.
