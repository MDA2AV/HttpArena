# aspnet-minimal-11

aspnet-minimal on .NET 11 preview 7 with runtime async on. Same source and configuration as [aspnet-minimal](../aspnet-minimal/); the runtime version and `<Features>runtime-async=on</Features>` in the csproj are the only differences, so the two entries side by side measure that one switch.

## Stack

- **Language:** C# / .NET 11 preview 7, runtime async on
- **Framework:** ASP.NET Core Minimal APIs
- **Engine:** Kestrel
- **Build:** Framework-dependent publish, `mcr.microsoft.com/dotnet/aspnet:11.0.0-preview.7` runtime (Ubuntu 26.04) with `libmsquic` installed for HTTP/3

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}` | GET | Returns `count` items from the preloaded dataset; honors `Accept-Encoding: gzip/br/deflate` for the `json-comp` profile |
| `/async-db` | GET | Postgres range query: `SELECT ... WHERE price BETWEEN $min AND $max LIMIT $limit` |
| `/echo` | POST | Returns the request body back verbatim |
| `/crud/items` | GET | Paginated list by category with two queries (data + count) |
| `/crud/items/{id}` | GET | Single item read with `IMemoryCache` (1s TTL), returns `X-Cache: HIT/MISS` |
| `/crud/items` | POST | Create item via INSERT with ON CONFLICT upsert, returns 201 |
| `/crud/items/{id}` | PUT | Update item and invalidate cache entry |
| `/static/*` | GET | Serves files from `/data/static` via `MapStaticAssets` with precomputed ETags + compression |

## Notes

- HTTP/1.1 on port 8080, HTTP/1+2+3 on port 8443 (TCP **and** UDP for QUIC), h1+TLS on port 8081 (`json-tls` profile)
- HTTP/3 via MsQuic (`libmsquic` installed in the runtime image); Kestrel advertises h3 through the default Alt-Svc header so clients upgrade from h2
- TLS certs loaded from `$TLS_CERT` / `$TLS_KEY` (default `/certs/server.crt` + `/certs/server.key`)
- Logging disabled (`ClearProviders()`) for throughput; `Server: aspnet-minimal` header set via a lightweight middleware
- `AddResponseCompression()` + `UseResponseCompression()` drives `/json/{count}` gzip encoding for the `json-comp` profile
- HTTP/2 tuned: 256 max streams per connection, 2 MB initial connection window, 1 MB stream window
- `/echo` reads the request body into a 64 KB pooled buffer (`ArrayPool<byte>.Shared`) and returns those bytes back unchanged — no full-body allocation
- JSON responses use source-generated `JsonSerializerContext` (`AppJsonContext`) so the hot path avoids reflection
- Postgres pooled via `Npgsql.NpgsqlDataSource` built once at startup from `DATABASE_URL`
- Source split: `Program.cs` (startup + Kestrel + routes), `Handlers.cs` (HTTP adapters), `Services/` (framework-agnostic application logic: dataset, Postgres/Redis connections, item queries, fortunes), `Types/` (DTOs + JSON serializer context). `Services/` and `Types/` have no ASP.NET dependencies and can be copied as-is into other framework integrations.
