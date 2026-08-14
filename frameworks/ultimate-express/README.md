# ultimate-express

The Express 4 API reimplemented on uWebSockets.js, with the cluster module for multi-core scaling.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [ultimate-express](https://github.com/dimdenGD/ultimate-express) (Express API on uWebSockets.js)
- **Build:** Multi-stage on `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/json/:count` | GET | Serializes a slice of the dataset, gzip or brotli when the client accepts one |
| `/db` | GET | Reads from SQLite, read-only, memory mapped |
| `/async-db` | GET | Reads from PostgreSQL through a pool of four |
| `/upload` | POST | Counts the bytes of the request body |
| `/static/:filename` | GET | Serves a file from disk, the brotli or gzip variant when the client accepts one |

## Notes

Tuned mode: compression is negotiated by hand per request (gzip level 1, brotli quality 3, nothing
without Accept-Encoding). Static files are read from disk on every request, per the arena rules:
only the list of names, existing pre-compressed variants and content types is scanned at startup.
Routes with a parameter are handed to the µWS router rather than matched in JavaScript.
