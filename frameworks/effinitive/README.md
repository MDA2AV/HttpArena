# effinitive

Ultra-high-performance custom HTTP server for .NET 10 — built from scratch for maximum speed.

## Stack

- **Language:** C# / .NET 10
- **Framework:** Effinitive
- **Engine:** Effinitive
- **Build:** Framework-dependent publish, `mcr.microsoft.com/dotnet/runtime:10.0` runtime with `libmsquic` installed for HTTP/3

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}` | GET | Returns `count` items from the preloaded dataset |
| `/compression` | GET | Gzip-compressed large JSON response |
| `/db` | GET | SQLite range query with JSON response |
| `/async-db` | GET | PostgreSQL async range query |
| `/upload` | POST | Streams request body, returns byte count |
| `/static/*` | GET | Serves files from `/data/static` with MIME types and ETag support |
| `/ws` | GET | WebSocket echo — reflects text, binary, and ping/pong frames |

## Notes

- HTTP/1.1 on port 8080, HTTP/1+2+3 on port 8443 (TCP **and** UDP for QUIC)
- HTTP/3 via MsQuic (`libmsquic` installed in the runtime image); ALPN negotiation handles h2/h3 upgrade
- TLS certs loaded from `$TLS_CERT` / `$TLS_KEY` (default `/certs/server.crt` + `/certs/server.key`)
- Static files served from the `/data/static` volume mount at runtime; no files baked into the image
- JSON responses use source-generated `JsonSerializerContext` (`AppJsonContext`) so the hot path avoids reflection
- Postgres pooled via `Npgsql.NpgsqlDataSource` with multiplexing, built once at startup from `DATABASE_URL`
- WebSocket endpoint at `/ws` handles text, binary, and ping/pong frames; non-upgrade requests to `/ws` return 400
- Source split: `Program.cs` (startup + routing), `Models.cs` (DTOs + JSON context), `Tests/` (one file per test profile)
