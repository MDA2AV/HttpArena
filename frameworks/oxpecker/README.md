# oxpecker

F# web framework built on ASP.NET Core endpoint routing, running on .NET 10 with Kestrel.

## Stack

- **Language:** F# / .NET 10
- **Framework:** Oxpecker 2.1 (+ Oxpecker.ViewEngine 2.0)
- **Engine:** Kestrel
- **Build:** Framework-dependent publish, `mcr.microsoft.com/dotnet/aspnet:10.0` runtime (Debian 12) with `libmsquic` installed for HTTP/3

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}` | GET | Returns `count` items from the preloaded dataset; honors `Accept-Encoding: gzip/br` for the `json-comp` profile |
| `/async-db` | GET | Postgres range query: `SELECT ... WHERE price BETWEEN $1 AND $2 LIMIT $3` |
| `/upload` | POST | Streams the request body and returns the byte count |
| `/crud/items` | GET | Paginated list by category |
| `/crud/items/{id}` | GET | Single item read, cache-aside with 200ms TTL, returns `X-Cache: HIT/MISS` |
| `/crud/items` | POST | Create item via INSERT with ON CONFLICT upsert, returns 201 |
| `/crud/items/{id}` | PUT | Update item and invalidate cache entry |
| `/fortunes` | GET | DB query + HTML table rendered with Oxpecker.ViewEngine |
| `/static/*` | GET | Serves the static assets straight from the mounted `/data/static` |

## Notes

- Routing via Oxpecker's `Endpoint list` DSL: verb groups, typed `routef`, crud grouped under one `subRoute "/crud/items"`
- `ctx.TryGetQueryValue` / `ctx.BindJson` for input, `ctx.WriteText` / `WriteJsonChunked` / `WriteHtmlViewChunked` for output
- `/fortunes` rendered with Oxpecker.ViewEngine (`Views.fs`); escaping and doctype come from the engine
- `Services/` are plain F# modules called directly from handlers — no DI singletons; `Program.fs` touches them at startup to load the dataset and open the pools
- HTTP/1.1 on port 8080, HTTP/1+2+3 on port 8443 (TCP **and** UDP for QUIC), h1+TLS on 8081, prior-knowledge h2c on 8082
- TLS certs from `$TLS_CERT` / `$TLS_KEY` (default `/certs/server.crt` + `/certs/server.key`); TLS listeners skipped when absent
- HTTP/2 tuned: 256 max streams per connection, 2 MB initial connection window, 1 MB stream window
- `AddResponseCompression()` + `UseResponseCompression()` for `json-comp`
- `UseStaticFiles` for `/static/*` with a `PhysicalFileProvider` on `/data/static`, so what is served follows the directory the harness mounts rather than a build-time copy in `wwwroot` (see #1268); `.webp` and `.woff2` are added to the content type provider, and compression is left to the response compression middleware
- `/upload` drains the body through a 64 KB pooled buffer (`ArrayPool<byte>.Shared`)
- Postgres pooled via `NpgsqlDataSource` with auto-prepare; crud read cache is Redis when `REDIS_URL` is set, else in-process `MemoryCache`
- Logging disabled (`ClearProviders()`); `ServerGarbageCollection` enabled
- Project is `HttpArena.Oxpecker.fsproj` — an assembly named `oxpecker` collides with the `Oxpecker` package it depends on
