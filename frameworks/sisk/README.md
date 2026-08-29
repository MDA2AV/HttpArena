# Sisk

Sisk is a lightweight, agnostic, simple, and robust web development framework.

## Stack

- **Language:** C# / .NET 10
- **Framework:** Sisk
- **Engine:** Sisk
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
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{filename}` | GET | Serves preloaded static files with MIME types |

## Notes

- Self-contained single-file deployment
