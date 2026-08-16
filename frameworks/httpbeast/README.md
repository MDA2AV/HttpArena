# httpbeast

HttpBeast, the epoll HTTP server that Jester and Prologue are built on, called
directly.

## Stack

- **Language:** Nim 2.2.4
- **Framework:** HttpBeast 0.4.2, gzip from zippy 0.10.19
- **Build:** `nimlang/nim:2.2.4`, `nim c -d:release --mm:orc --threads:on`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Returns the byte count of the body |

## Notes

- One httpbeast thread per available core, each with its own SO_REUSEPORT
  listener, so there is no primary process to fan requests out
- The thread count comes from the cgroup CPU quota when there is one, and from
  the host CPU count otherwise, the same way koa's `getCPUCount` does it
- Routing is a hand-written match on the request target, because httpbeast has
  no router
- JSON is written by hand from a per-item prefix built at startup, so a request
  only appends `total` and the closing brace
- Compression is gzip from zippy, negotiated per request on `Accept-Encoding`.
  This is what makes the mode `tuned`: httpbeast has no compression middleware
- The dataset is read once before the threads start; a missing file leaves an
  empty list instead of failing the boot
- httpbeast reads a request body by `Content-Length` only and would answer a
  chunked request before the body arrived. The build applies
  `httpbeast-chunked.patch` to the pinned source: the read loop waits for the
  zero size last chunk and keeps the header end position stable. The handler
  then gets the raw chunked bytes and `main.nim` decodes them by hand
