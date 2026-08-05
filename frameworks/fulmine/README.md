# fulmine

A drop-in replacement for Express 5 running on uWebSockets.js, with the cluster module for multi-core scaling.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 22
- **Framework:** [fulmine.js](https://github.com/nigrosimone/fulmine.js) (Express 5 API on uWebSockets.js)
- **Build:** Multi-stage, `node:22` build to `ubuntu:24.04` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/json/:count` | GET | Serializes a slice of the dataset |
| `/async-db` | GET | Reads from PostgreSQL, prepared statement, pool sized under max_connections |
| `/upload` | POST | Counts the bytes of the request body |
| `/static/:filename` | GET | Serves a file from disk, the brotli or gzip variant when the client accepts one |

## Notes

Two things this entry relies on that are worth naming, because they are where the framework differs
from Express rather than where it is the same:

- Routes with a parameter, `/json/:count` and `/static/:filename`, are handed to the µWS router
  rather than matched in JavaScript.
- A handler simple enough to be read at registration time is compiled into a µWS declarative
  response. `/pipeline` is one, so it is answered without entering JavaScript.
