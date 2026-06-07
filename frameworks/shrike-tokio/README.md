# shrike-tokio

An **epoll** engine with an IVTS-backed, **`RunContinuationsAsynchronously = true`**
async handler loop, fixed the **Tokio way**: the driver only signals *readiness*,
never data.

## The model (why there is no race)

- The **worker thread is a pure readiness notifier**: `epoll_wait` → `SignalReadable`
  → wake the handler. It **never touches the socket or the recv buffer**.
- The **handler** resumes on the **thread pool** and does its **own `recv()`**
  (`Connection.DoRecv`) into its buffer, then parses and responds.

Because only the handler ever touches the recv buffer, the buffer is owned by a
single thread — there is **no driver/handler data race**. (The sibling
`shrike-minima` solves the same problem with an SPSC recv ring instead.)

This mirrors Tokio/mio: the reactor flips a per-fd readiness atomic + Waker and
wakes the task; the **task** does the read on its worker thread.

## Handler (`Program.cs`)

Hand-rolled HTTP/1.1 over the recv buffer: request line, `Content-Length` and
chunked bodies, keep-alive, pipelining, fragmented-read reassembly. `Connection:
close` sends a FIN via `shutdown(SHUT_WR)`.

| Endpoint | Response |
|---|---|
| `GET/POST /baseline11?a=&b=` | `text/plain` — `a + b` (+ POST body) |
| `GET /pipeline` | `text/plain` — `ok` |

## Tests

`baseline`, `pipelined`, `limited-conn`. epoll (not io_uring). `SHRIKE_PORT` /
`SHRIKE_WORKERS` override for local runs.
