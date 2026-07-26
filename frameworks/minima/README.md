# minima

The **Minima** io_uring engine serving the H1-isolated profiles (`baseline`,
`pipelined`, `limited-conn`, `json`). Minima is a from-scratch C# multi-reactor
io_uring server; this entry vendors the engine unchanged and adds a hand-rolled
HTTP/1.1 handler (no HTTP framework).

## Engine (vendored as-is)
- **Per-reactor SO_REUSEPORT + multishot accept** — each reactor thread owns its
  own listener and ring; the kernel shards connections (no central acceptor).
- **Multishot recv into a provided buffer ring**.
- **RCA=false inline continuations** — handler resumes inline on the reactor
  thread, and `Enqueue{Return,Flush,Recycle}` short-circuit straight to the ring
  (no MPSC queue / eventfd wake) since the caller is the reactor thread.

## Handler (`Program.cs`)
Hand-rolled HTTP/1.1: request line + headers, `Content-Length` and chunked
bodies, keep-alive, pipelining (responses batched per drain), and fragmented-read
reassembly.

| Endpoint | Response |
|---|---|
| `GET/POST /baseline11?a=&b=` | `text/plain` — `a + b` (+ POST body as an integer) |
| `GET /pipeline` | `text/plain` — `ok` |
| `GET /json/{count}?m=N` | `application/json` — `{items:[…],count}`, each item with `total = price*quantity*N` |

For `json`, each item's static JSON is precomputed from the mounted
`/data/dataset.json` at startup; a request only appends the dynamic `total`.

io_uring needs `seccomp=unconfined` (harness-provided; `engine: "io_uring"` makes
validate.sh enable it). `MINIMA_PORT` / `MINIMA_REACTORS` / `MINIMA_DATASET`
override for local runs.
