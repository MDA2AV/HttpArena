# fulmine

A drop-in replacement for Express 5 running on uWebSockets.js, with its own `cluster` option for multi-core scaling.

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
| `/static/*` | GET | `express.static()` with `preCompressed`, so the `.br` or `.gz` on disk is served when the client accepts one |

## Notes

This is a standard entry: every route goes through a documented framework API, with no hand-rolled
compression, no suffix lookup and nothing held in memory. Four things it relies on are worth naming,
because they are where the framework differs from Express rather than where it is the same:

- Routes with a parameter, `/json/:count` among them, are handed to the µWS router rather than
  matched in JavaScript.
- A handler simple enough to be read at registration time is compiled into a µWS declarative
  response. `/pipeline` is one, so it is answered without entering JavaScript.
- `express.compression()` is the framework's own, taking the compression module's options: it is
  mounted on the json route, which is the only one the profiles ask to compress.
- `express.static(dir, { preCompressed: true })` is the framework's documented way of serving the
  `.br` and `.gz` files the harness leaves on disk. `app.set("file cache", false)` turns off the
  small-file cache, so every request reads the file it answers with.
- `express({ cluster: "auto" })` is the framework's own fork, so there is no cluster boilerplate in
  the entry: one worker per usable core, each binding the same port with uWS's shared flag, which
  is `SO_REUSEPORT`. The kernel picks which worker gets a connection and the primary is not in the
  path, unlike node's `cluster` with an `http.Server`, where the primary accepts and passes each
  connection on. "auto" reads the cgroup quota first, so the worker count is the container's cores
  and not the host's.
