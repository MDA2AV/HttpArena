# koa

Koa on the Node `http` server, default configuration.

## Stack

- **Language:** Node 26
- **Framework:** Koa 3 with @koa/router
- **Build:** `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing and path parameters through @koa/router
- JSON serialized by koa from the response body object
- Compression through the koa-compress middleware with its defaults
- One cluster worker per available core, as Node has a single-threaded event loop
