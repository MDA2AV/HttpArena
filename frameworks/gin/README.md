# gin

Gin web framework on the Go `net/http` server, default configuration.

## Stack

- **Language:** Go 1.26
- **Framework:** Gin 1.12
- **Build:** `golang:1.26-alpine` -> `alpine:3.23` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- Routing and path parameters through the Gin router, JSON through `c.JSON`
- Compression through the `gin-contrib/gzip` middleware
- Release mode, only the Recovery middleware is installed
