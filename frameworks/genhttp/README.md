# GenHTTP

Lightweight embeddable C# web server using the GenHTTP library on the internal engine.

## Stack

- **Language:** C# / .NET 10 (Alpine)
- **Framework:** GenHTTP
- **Engine:** GenHTTP
- **Build:** Self-contained musl publish, `runtime-deps:10.0-alpine`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json` | GET | Processes 50-item dataset, serializes JSON |
| `/compression` | GET | Gzip-compressed large JSON response |
| `/db` | GET | SQLite range query with JSON response |
| `/upload` | POST | Receives 1 MB body, returns byte count |
| `/static/{filename}` | GET | Serves preloaded static files with MIME types |

## Notes

- Implemented via web services and a layout router
- Compression and routing modules
- Self-contained single-file deployment
