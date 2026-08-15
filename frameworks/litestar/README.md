# litestar

Litestar 2 on uvicorn, one worker per core.

## Stack

- **Language:** Python 3.13
- **Framework:** Litestar 2.24
- **Server:** uvicorn 0.40 with uvloop and httptools

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing, path and query parameter injection through the Litestar handlers
- JSON serialized per request by the default msgspec encoder
- Compression through `CompressionConfig(backend="gzip")`
- `request_max_body_size` raised to 30 MB so the upload profile is not rejected
