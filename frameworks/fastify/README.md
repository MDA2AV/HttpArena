# fastify

Fastify 5 on node's own HTTP server, with the cluster module for multi-core scaling.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [Fastify 5](https://github.com/fastify/fastify) on `node:http`
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
| `/static/:filename` | GET | Serves a file from disk through `@fastify/static` |

## Notes

- Standard mode: compression is `@fastify/compress` and static files are `@fastify/static`, both
  registered with their default settings.
- The default body parsers are replaced with a single catch-all that hands the raw stream
  through, since the two POST endpoints only count or sum what arrives.
- Logging is off and responses are plain strings and Buffers with the content type set by hand,
  so no serializer or schema machinery runs per request.
