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
| `/crud/items` | GET/POST | Lists items by category with paging, or inserts one |
| `/crud/items/:id` | GET/PUT | Reads one item through a Redis cache-aside, or updates it and drops the cached copy |
| `/fortunes` | GET | Reads 200 rows from PostgreSQL, appends the runtime row, sorts and renders the HTML table |

## Notes

Tuned mode: compression is negotiated by hand per request (gzip level 1, brotli quality 3, nothing
without Accept-Encoding). Static files are read from disk on every request, per the arena rules:
only the list of names, existing pre-compressed variants and content types is scanned at startup.
Routes with a parameter are handed to the µWS router rather than matched in JavaScript.

`fortunes` is rendered by hand rather than through a template engine, which tuned mode allows;
the handler still queries per request, appends the runtime row, sorts and escapes `<`, `>`, `&`,
`"` and `'`.

`json-tls` and `static-tls` listen on `8081` when `/certs/server.crt` and `/certs/server.key` are
mounted. ultimate-express takes TLS material through the uWS options at construction rather than
through a separate `https` server, so the port is a second app carrying the same routes. Every
worker in the cluster binds it, exactly as they all bind `8080`.

`express.json()` is mounted on the two crud routes that carry a body rather than globally, so
`/upload` keeps counting its 20MB body as it streams instead of having it buffered and parsed.
