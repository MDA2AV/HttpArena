# hyper-express

An Express-like API on uWebSockets.js, with the cluster module for multi-core scaling.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [hyper-express](https://github.com/kartikk221/hyper-express) (Express-like API on uWebSockets.js)
- **Build:** Multi-stage on `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/json/:count` | GET | Serializes a slice of the dataset, gzip or brotli when the client accepts one |
| `/upload` | POST | Counts the bytes of the request body |

## Notes

Three things this entry relies on, because they are where hyper-express differs from Express rather
than where it looks the same:

- It is its own `Server` class, not an `express()` factory, and handlers take `(request, response)`.
  The body is read with `await request.text()` instead of a body parser, and the query and the route
  parameter come from `request.query_parameters` and `request.path_parameters`.
- `max_body_length` defaults to 250 KB and answers 413 above it, so the upload profile needs it
  raised. `/upload` still reads the request as a stream and counts the chunks, so a 20 MB body is
  never held in memory.
- Tuned mode, for the same reason as ultimate-express and fulmine: the framework ships no response
  compression, so `/json/:count` negotiates by hand per request (gzip level 1, brotli quality 3,
  nothing without `Accept-Encoding`). Standard mode asks for the framework's own compression
  middleware, and there is none to use.

Every worker binds `:8080` on its own: uWebSockets.js shares the port across processes unless
`exclusive_port` is asked for, so the cluster fork per core needs nothing else.
