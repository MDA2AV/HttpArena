# uWebSockets.js

uWebSockets.js, the Node binding of the uWebSockets C++ server.

## Stack

- **Language:** Node 24
- **Framework:** uWebSockets.js 20.69
- **Build:** `node:24-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing, query and body handling through the uWS `App` API
- JSON serialized per request with `JSON.stringify`
- uWebSockets.js ships no compression middleware, so `json-comp` gzips the body
  with the Node zlib bindings when the request asks for it
- One cluster worker per available core, listening on the same port as the
  uWebSockets clustering example does
