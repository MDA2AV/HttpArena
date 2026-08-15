# node-h3

H3 v2 on node's own HTTP server, with the cluster module for multi-core scaling.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [H3 v2](https://github.com/h3js/h3) served on `node:http` by [srvx](https://srvx.h3.dev/)
- **Build:** Multi-stage on `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/json/:count` | GET | Serializes a slice of the dataset, gzip when the client accepts it |
| `/upload` | POST | Counts the bytes of the request body |

## Notes

- H3 v2 is web-standard: handlers get a `Request` and return a value, and `serve()` is srvx
  picking `node:http` on this runtime. Returned values go through the framework response
  pipeline, so `/json` is serialized by H3 itself.
- H3 ships no compression middleware, so `json-comp` is negotiated in the handler with
  `node:zlib` at its default settings. Without `Accept-Encoding` the response is not compressed.
- `serve()` gets `reusePort`, the srvx option for a non-exclusive bind. It is what lets the
  cluster workers share port 8080. The default is an exclusive bind, and then only the first
  worker gets the port while the others fail with `EADDRINUSE` without saying so, because srvx
  catches the listen error.
