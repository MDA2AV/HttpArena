# fastendpoints

[FastEndpoints](https://fast-endpoints.com/) HTTP server using .NET 10 with Kestrel — a REPR-pattern
(Request-Endpoint-Response) endpoint framework built on top of ASP.NET Core.

## Stack

- **Language:** C# / .NET 10
- **Framework:** FastEndpoints 8.x
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
| `/static/*` | GET | Serves files from `/data/static` via `MapStaticAssets` with precomputed ETags + compression |

## Notes

- Endpoints follow the idiomatic FastEndpoints style: one endpoint class per route with a
  request DTO bound from route/query/body and `Send.*` response methods. Baseline/upload
  endpoints use `EndpointWithoutRequest` and read the raw body directly.
- No `/fortunes` entry: server-rendered HTML templating is outside FastEndpoints' scope
  (the aspnet-minimal entry covers that profile via Razor Pages).
- HTTP/1.1 on port 8080, HTTP/1+2+3 on port 8443 (TCP **and** UDP for QUIC), h1+TLS on port 8081 (`json-tls` profile)
- HTTP/3 via MsQuic (`libmsquic` installed in the runtime image); Kestrel advertises h3 through the default Alt-Svc header so clients upgrade from h2
- TLS certs loaded from `$TLS_CERT` / `$TLS_KEY` (default `/certs/server.crt` + `/certs/server.key`)
- Logging disabled (`ClearProviders()`) for throughput; `Server: fastendpoints` header set via a lightweight middleware
- `AddResponseCompression()` + `UseResponseCompression()` drives `/json/{count}` gzip encoding for the `json-comp` profile
- HTTP/2 tuned: 256 max streams per connection, 2 MB initial connection window, 1 MB stream window
- JSON responses use source-generated `JsonSerializerContext` (`AppJsonContext`) inserted into the FastEndpoints serializer options; request DTOs fall back to the default reflection resolver
- Postgres pooled via `Npgsql.NpgsqlDataSource` built once at startup from `DATABASE_URL`
- Source split: `Program.cs` (startup + Kestrel), `Endpoints/` (FastEndpoints endpoint classes), `Services/` + `Types/` (framework-agnostic application layer, copied verbatim from the aspnet-minimal entry — no ASP.NET or FastEndpoints dependencies)
