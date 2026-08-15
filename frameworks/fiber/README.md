# fiber

Fiber web framework on fasthttp, default configuration.

## Stack

- **Language:** Go 1.26
- **Framework:** Fiber 3
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

- Routing and path/query access through the Fiber API
- JSON through `c.JSON`, serialized per request
- Compression through the Fiber `compress` middleware
- Body limit raised to 25 MB so the upload profile is not rejected
