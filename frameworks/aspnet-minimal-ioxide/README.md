# aspnet-minimal-ioxide

Minimal ASP.NET Core HTTP server using .NET 11 with Kestrel on the **ioxide io_uring transport** and minimal API routing. Identical to `aspnet-minimal` — the only code difference is `builder.WebHost.UseIoxide()`.

> **Scope:** HTTP/1.1 only — plaintext (8080) and **HTTP/1.1-over-TLS (`json-tls`, 8081) terminated via kTLS** (`ioxide.tls`): the transport runs the TLS 1.3 handshake and the kernel does the record crypto, so Kestrel gets plaintext (no `UseHttps`/SslStream). kTLS requires the host `tls` kernel module. HTTP/2 (cleartext + TLS) and HTTP/3 are intentionally omitted.

## Stack

- **Language:** C# / .NET 11
- **Framework:** ASP.NET Core Minimal APIs
- **Engine:** Kestrel on the ioxide io_uring transport (`ioxide.Kestrel`, `UseIoxide()`, default reactor count)
- **Build:** Framework-dependent publish, `mcr.microsoft.com/dotnet/aspnet:11.0-preview` runtime (Debian 12)

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}` | GET | Returns `count` items from the preloaded dataset; honors `Accept-Encoding: gzip/br/deflate` for the `json-comp` profile |
| `/async-db` | GET | Postgres range query: `SELECT ... WHERE price BETWEEN $min AND $max LIMIT $limit` |
| `/upload` | POST | Streams the request body and returns the byte count |
| `/crud/items` | GET | Paginated list by category with two queries (data + count) |
| `/crud/items/{id}` | GET | Single item read with `IMemoryCache` (1s TTL), returns `X-Cache: HIT/MISS` |
| `/crud/items` | POST | Create item via INSERT with ON CONFLICT upsert, returns 201 |
| `/crud/items/{id}` | PUT | Update item and invalidate cache entry |
| `/static/*` | GET | Serves files from `/data/static` via `MapStaticAssets` with precomputed ETags + compression |

## Notes

- HTTP/1.1 on port 8080, HTTP/1+2+3 on port 8443 (TCP **and** UDP for QUIC), h1+TLS on port 8081 (`json-tls` profile)
- HTTP/3 via MsQuic (`libmsquic` installed in the runtime image); Kestrel advertises h3 through the default Alt-Svc header so clients upgrade from h2
- TLS certs loaded from `$TLS_CERT` / `$TLS_KEY` (default `/certs/server.crt` + `/certs/server.key`)
- Logging disabled (`ClearProviders()`) for throughput; `Server: aspnet-minimal-ioxide` header set via a lightweight middleware
- `AddResponseCompression()` + `UseResponseCompression()` drives `/json/{count}` gzip encoding for the `json-comp` profile
- HTTP/2 tuned: 256 max streams per connection, 2 MB initial connection window, 1 MB stream window
- `/upload` reads the request body into a 64 KB pooled buffer (`ArrayPool<byte>.Shared`) and returns the byte count — no full-body allocation
- JSON responses use source-generated `JsonSerializerContext` (`AppJsonContext`) so the hot path avoids reflection
- Postgres pooled via `Npgsql.NpgsqlDataSource` built once at startup from `DATABASE_URL`
- Source split: `Program.cs` (startup + Kestrel), `Handlers.cs` (routes + JSON ctx), `AppData.cs` (dataset + pg pool), `Models.cs` (DTOs)
- **Transport:** `builder.WebHost.UseIoxide()` swaps Kestrel's default sockets transport for the ioxide io_uring transport (one io_uring ring per reactor thread, request loop pinned to the reactor). `ioxide.Kestrel` resolves from nuget.org; until 0.0.13 is published there, `nuget.config` adds a local feed.
- **Reactor count:** default = `Environment.ProcessorCount` **per bound listener**. This app binds multiple listeners (h1, h2c, and TLS h1/h2/h3 when certs are present), so the total ring count is `listeners × ProcessorCount`. If that's too many io_uring rings for your box, set `UseIoxide(o => o.ReactorCount = N)`.
