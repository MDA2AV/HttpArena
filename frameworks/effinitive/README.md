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
| `/delay/{ms}` | GET | Waits the milliseconds named in the path and echoes them back |
| `/json/{count}` | GET | Returns `count` items from the preloaded dataset |
| `/async-db` | GET | PostgreSQL async range query |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/*` | GET | Serves files from `/data/static` with MIME types and ETag support |
| `/ws` | GET | WebSocket echo — reflects text, binary, and ping/pong frames |

## Notes

- Listeners:

  | Port | Serves |
  |---|---|
  | 8080 | HTTP/1.1 cleartext |
  | 8081 | HTTP/1.1 over TLS, ALPN `http/1.1` |
  | 8082 | HTTP/2 cleartext (h2c, prior knowledge) |
  | 8443 | h2 and http/1.1 over TLS, plus HTTP/3 over QUIC (TCP **and** UDP) |
  | 9000 | HTTP/1.1 over TLS, `tls_check` only |

- HTTP/3 via MsQuic (`libmsquic` installed in the runtime image); ALPN negotiation handles h2/h3 upgrade
- TLS certs loaded from `$TLS_CERT` / `$TLS_KEY` (default `/certs/server.crt` + `/certs/server.key`); the
  `tls_check` listener from `$TLS_CHECK_CERT` / `$TLS_CHECK_KEY` (default `/certs-tls/...`), resolved per
  handshake so a replaced pair is served without a restart
- Static files served from the `/data/static` volume mount at runtime; no files baked into the image
- JSON responses use source-generated `JsonSerializerContext` (`AppJsonContext`) so the hot path avoids reflection
- Postgres pooled via `Npgsql.NpgsqlDataSource` with multiplexing, built once at startup from `DATABASE_URL`
- WebSocket endpoint at `/ws` handles text, binary, and ping/pong frames; a non-upgrade GET to `/ws` returns 404
- TLS connections send a `close_notify` before closing
- Source split: `Program.cs` (startup + routing), `Models.cs` (DTOs + JSON context), `Tests/` (one file per test profile)
