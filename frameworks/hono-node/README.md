# hono-node

Hono on node's own HTTP server through the official `@hono/node-server` adapter, with the cluster
module for multi-core scaling.

## Stack

- **Language:** TypeScript
- **Runtime:** Node.js 26
- **Framework:** [Hono 4](https://github.com/honojs/hono) on `node:http` via
  [@hono/node-server](https://github.com/honojs/node-server)
- **Build:** Multi-stage on `node:26-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/json/:count` | GET | Serializes a slice of the dataset |
| `/upload` | POST | Counts the bytes of the request body |

## Notes

- The handlers are the same code as `hono-bun`, so the two entries differ only in the runtime and
  in how the server is started: Bun serves `app.fetch` natively with `reusePort`, here the adapter
  puts it on `node:http` and the cluster module forks one worker per core, counted from the cgroup
  quota like the other node entries do.
- Standard mode: compression is Hono's own `compress()` middleware, which on Node encodes with
  `CompressionStream` and negotiates gzip per request. It is mounted on `/json/*` only, so the
  other endpoints don't pay the encoder cost.
- The dataset is read at startup from `DATASET_PATH` or `/data/dataset.json`; a missing file serves
  an empty list instead of taking the worker down.
- TypeScript runs as it is, node 26 strips the types on load, so the image needs no build step.
