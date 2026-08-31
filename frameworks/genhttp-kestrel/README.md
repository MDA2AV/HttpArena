# GenHTTP

Lightweight embeddable C# web server using the GenHTTP library on the internal engine.

## Stack

- **Language:** C# / .NET 10
- **Framework:** GenHTTP
- **Engine:** GenHTTP
- **Build:** Self-contained musl publish

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
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{filename}` | GET | Serves preloaded static files with MIME types |

## Notes

- Implemented via web services and a layout router
- Compression and routing modules
- Self-contained single-file deployment
