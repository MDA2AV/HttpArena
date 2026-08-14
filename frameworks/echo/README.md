# echo

Echo v4 on the Go `net/http` server, default configuration.

## Stack

- **Language:** Go 1.26
- **Framework:** Echo v4
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

- Routing and path parameters through the Echo router, JSON through `c.JSON`
- Compression through the Echo `Gzip` middleware
- Banner and port log disabled, no other middleware installed
