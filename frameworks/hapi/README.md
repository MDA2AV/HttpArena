# hapi

hapi on the Node `http` server, default configuration.

## Stack

- **Language:** Node 26
- **Framework:** hapi 21 (`@hapi/hapi`), no plugins
- **Build:** `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/delay/{ms}` | GET | Waits `ms` milliseconds, returns `ms` |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Routing, path parameters, query parsing and payload parsing are hapi's own
- JSON serialized by hapi from the returned object
- Compression is hapi's built-in response compression. gzip is hapi's default; brotli is
  registered with `server.encoder('br', ...)` using Node's `zlib` at quality 3, and is what
  hapi picks when the client accepts both
- `/echo` uses `payload.parse: false` for the raw Buffer and `response.emptyStatusCode: 200`,
  since hapi otherwise answers an empty payload with 204
- Port 8081 is a second hapi server with the `tls` option, registering the same route plugin
- One cluster worker per available core, as Node has a single-threaded event loop
