# shrike-minima

An **epoll** engine with an IVTS-backed, **`RunContinuationsAsynchronously = true`**
async handler loop, fixed the **Minima way**: an **SPSC recv ring** decouples the
worker from the handler.

## The model (why there is no race)

- The **worker** recv's into **pooled buffers** and **enqueues** `(ptr, len)` onto a
  per-connection **single-producer / single-consumer ring** (`SpscRing`), then signals.
- The **handler** resumes on the **thread pool**, **dequeues** the chunks, **copies**
  each into its own parse buffer, **returns** the buffer to the pool, and parses.

The worker and handler touch **disjoint ends** of the ring (tail / head, release/acquire),
and each recv buffer is owned by one side at a time — so the recv buffer is **never
shared**, and there's no driver/handler data race. Unlike the Tokio-style sibling
(`shrike-tokio`, where the handler does its own `recv`), here **recv pipelines with
parse**: the worker keeps pumping recv into the ring while the handler is still parsing.
The cost is one extra copy (chunk → parse buffer) plus the pool/ring bookkeeping.

This is the epoll analogue of Minima's `SpscRecvRing` (io_uring provided buffers there;
pooled `recv()` buffers here).

## Handler (`Program.cs`)

Hand-rolled HTTP/1.1 over the parse buffer: request line, `Content-Length` and chunked
bodies, keep-alive, pipelining, fragmented-read reassembly. `Connection: close` sends a
FIN via `shutdown(SHUT_WR)`.

| Endpoint | Response |
|---|---|
| `GET/POST /baseline11?a=&b=` | `text/plain` — `a + b` (+ POST body) |
| `GET /pipeline` | `text/plain` — `ok` |

## Tests

`baseline`, `pipelined`, `limited-conn`. epoll (not io_uring). `SHRIKE_PORT` /
`SHRIKE_WORKERS` override for local runs.
