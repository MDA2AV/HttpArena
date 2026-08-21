# elysia

Ergonomic Bun-native TypeScript framework running a multi-process cluster behind Bun's HTTP server.

## Stack

- **Language:** TypeScript
- **Framework:** [Elysia](https://elysiajs.com) 1.4 + `@elysiajs/static`
- **Templates:** Handlebars (`views/fortunes.hbs`, embedded into the binary at build time)
- **Engine:** Bun (JavaScriptCore)
- **Build:** `bun build --compile --minify`, distroless runtime

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}` | GET | Returns `count` items from the preloaded dataset; honors `Accept-Encoding: gzip/br/deflate` (gzip via `Bun.gzipSync`, brotli via `node:zlib`, deflate via `Bun.deflateSync`) |
| `/async-db` | GET | Postgres range query: `SELECT ... WHERE price BETWEEN $min AND $max LIMIT $limit` |
| `/upload` | POST | Streams `request.body` via `for await` chunks, returns the byte count |
| `/static/*` | GET | Served by `@elysiajs/static` in dynamic mode (`alwaysStatic: false`) from `/data/static` |
| `/crud/items` | GET | Paginated list by `category`, `page`, `limit` |
| `/crud/items` | POST | Upsert via `INSERT ... ON CONFLICT DO UPDATE`, returns 201 |
| `/crud/items/{id}` | GET | Cache-aside read through Redis, `X-Cache: HIT`/`MISS` |
| `/crud/items/{id}` | PUT | Update, then invalidate the cached entry |
| `/fortunes` | GET | 200 rows plus one runtime row, sorted, rendered through Handlebars |

`/json/{count}` and `/static/*` are also served over TLS on port **8081** for the `json-tls` and
`static-tls` profiles, on a second Elysia instance whose `serve.tls` is handed to `Bun.serve`. The
listener only opens when the harness mounts `/certs`.

## Notes

- HTTP/1.1 on port 8080 (Bun has no native HTTP/2 server; h2/h2c/h3/grpc profiles are skipped)
- Multi-process cluster: one worker per CPU via `node:cluster`, rebalanced with `reusePort: true` so the kernel spreads accepts across workers (override with `ELYSIA_WORKERS`, ~150 MB RSS per worker)
- Dataset (`/data/dataset.json`) and the awaited `staticPlugin` are resolved at module top-level so `bun build --compile` doesn't trip over top-level `await` inside the cluster `else` branch
- Postgres through `Bun.SQL` and Redis through `Bun.RedisClient`, both shipped with the runtime, so the database profiles add no dependency. The pool is sized `DATABASE_MAX_CONN / workers` per worker so the cluster total matches the server's `max_connections`
- `fortunes` renders through Handlebars, which escapes `{{ }}` by default - the profile's load-bearing check. Standard mode requires a real template engine whose template is its own artifact, so `views/fortunes.hbs` is imported as text and embedded into the compiled binary rather than built as a string in the handler
- `/async-db` handler catches exceptions and returns an empty payload — `error:` callback style would mask the 500 status code
- `alwaysStatic: false` on `staticPlugin` avoids Bun's pre-buffered static route path which crashes on `Bun.file()` streams under `NODE_ENV=production`
