# GenHTTP (raw handlers)

Variant of the [genhttp](../genhttp/) entry that serves the benchmark endpoints with
hand-written `IHandler` implementations instead of reflection-based web services.
Routing (`Layout`), static files (`Assets`), compression and websockets are the
same as in the original entry.

## Stack

- **Language:** C# / .NET 11
- **Framework:** GenHTTP
- **Engine:** GenHTTP (internal)

## Endpoints

| Endpoint | Method | Handler |
|----------|--------|---------|
| `/pipeline` | GET | `FixedHandler` - shared `ok` content |
| `/baseline11`, `/baseline2` | GET, POST | `BaselineHandler` - sums `a`, `b` and the body |
| `/echo` | POST | `EchoHandler` - returns the request body |
| `/json/{count}?m=N` | GET | `JsonHandler` - dataset items with totals |
| `/delay/{ms}` | GET | `DelayHandler` - waits, then returns `ms` |
| `/async-db?min&max&limit` | GET | `AsyncDatabaseHandler` - Postgres range query |
| `/static/*` | GET | `Assets` with precompressed brotli files |
| `/ws` | GET | Websocket echo |

## Notes

- Query parameters and path segments are parsed from the raw request bytes,
  no strings are materialized.
- Request bodies are fetched with `GetBody(HeaderAccess.Release)` and
  `AsMemoryAsync()`, so the header is not copied and the body is a view into
  the read buffer of the connection.
- Response content instances are pooled and returned when the engine disposes
  them after writing.
- JSON is written with a reused `Utf8JsonWriter` directly into the response
  sink (per request, nothing is cached), which is why this entry is `tuned`.
