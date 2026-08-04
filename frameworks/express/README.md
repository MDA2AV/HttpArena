# express

Express 5 on node's own HTTP server, with the cluster module for multi-core scaling.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [Express 5](https://github.com/expressjs/express) on `node:http`
- **Build:** Multi-stage on `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/json/:count` | GET | Serializes a slice of the dataset |
| `/db` | GET | Reads from SQLite, read-only, memory mapped |
| `/async-db` | GET | Reads from PostgreSQL through a pool of four |
| `/upload` | POST | Counts the bytes of the request body |
| `/static/:filename` | GET | Serves a file from disk through `express.static` |

## Notes

- Standard mode: compression is the `compression` middleware and static files are
  `express.static`, both with their default settings.
- Plain Express 5 with no body parser mounted: the two POST endpoints read the request stream
  themselves, which is all they need.
- `x-powered-by` and `etag` are off, so the responses carry exactly the headers the profiles ask
  for and nothing computed per request that no profile reads.
