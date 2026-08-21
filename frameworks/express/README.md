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
| `/crud/items` | GET/POST | Lists items by category with paging, or inserts one |
| `/crud/items/:id` | GET/PUT | Reads one item through a Redis cache-aside, or updates it and drops the cached copy |
| `/fortunes` | GET | Reads 200 rows from PostgreSQL, appends the runtime row, sorts and renders `views/fortunes.hbs` |

## Notes

- Standard mode: compression is the `compression` middleware and static files are
  `express.static`, both with their default settings.
- `fortunes` renders through a view engine, which is what standard mode asks for: the template
  is its own artifact at `views/fortunes.hbs` and Handlebars escapes `{{ }}` by default, which
  is the check the profile calls load-bearing.
- `json-tls` and `static-tls` listen on `8081`, the same app behind a `node:https` server, when
  `/certs/server.crt` and `/certs/server.key` are mounted. Every worker binds it exactly as they
  all bind `8080`, so the cluster shares the port.
- `express.json()` is mounted on the two crud routes that carry a body rather than globally, so
  `/upload` keeps counting its 20MB body as it streams instead of having it buffered and parsed.
  The other two POST endpoints read the request stream themselves, which is all they need.
- `x-powered-by` and `etag` are off, so the responses carry exactly the headers the profiles ask
  for and nothing computed per request that no profile reads.
