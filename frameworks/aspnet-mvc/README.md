# aspnet-mvc

ASP.NET Core HTTP server using .NET 10 with Kestrel and MVC controller routing.

## Stack

- **Language:** C# / .NET 10
- **Framework:** ASP.NET Core MVC (attribute-routed controllers + Razor views)
- **Engine:** Kestrel
- **Build:** Framework-dependent publish, `mcr.microsoft.com/dotnet/aspnet:10.0` runtime (Debian 12) with `libmsquic` installed for HTTP/3

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
| `/crud/items` | GET | Paginated list by category |
| `/crud/items/{id}` | GET | Single item read with cache-aside (200ms TTL), returns `X-Cache: HIT/MISS` |
| `/crud/items` | POST | Create item via INSERT with ON CONFLICT upsert, returns 201 |
| `/crud/items/{id}` | PUT | Update item and invalidate cache entry |
| `/fortunes` | GET | Server-rendered HTML via an MVC controller + Razor view |
| `/static/*` | GET | Serves files from `/data/static` via `UseStaticFiles` |

## Notes

- HTTP/1.1 on port 8080, HTTP/1+2+3 on port 8443 (TCP **and** UDP for QUIC)
- TLS certs loaded from `$TLS_CERT` / `$TLS_KEY` (default `/certs/server.crt` + `/certs/server.key`)
- Logging disabled (`ClearProviders()`) for throughput; `Server: aspnet-mvc` header set via a lightweight middleware
- `AddResponseCompression()` + `UseResponseCompression()` drives `/json/{count}` gzip encoding for the `json-comp` profile
- JSON responses use a source-generated `JsonSerializerContext` (`AppJsonContext`) inserted into the MVC JSON options
- Postgres pooled via `Npgsql.NpgsqlDataSource` built once at startup from `DATABASE_URL`; optional Redis cache from `REDIS_URL` for the crud profile
- `/fortunes` renders through the standard MVC pipeline: `FortunesController` returns a `View()` backed by `Views/Fortunes/Index.cshtml`
- Source split: `Program.cs` (startup + Kestrel), `TestController.cs` / `CrudController.cs` / `FortunesController.cs` (HTTP adapters), `Services/` + `Types/` (framework-agnostic application layer shared with the other C# entries — no ASP.NET dependencies)
