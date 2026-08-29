# httpjl

HTTP.jl on its stream handler, the plain server the Julia ecosystem builds on.

## Stack

- **Language:** Julia 1.11
- **Framework:** HTTP.jl 2.6 over the Reseau transport
- **Build:** `julia:1.11.6-bookworm`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body in 64 KB chunks and returns the byte count |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- HTTP.jl directly, not Oxygen.jl on top of it: the six profiles need one router
  and one streaming body reader, which is what the stream handler already is,
  and a layer above it would only add its own dispatch to the measurement
- HTTP.jl 2 runs every connection as a task on Julia's `:interactive` thread
  pool, so one process uses every core. `start.sh` sizes that pool, cgroup v2
  quota first and the affinity mask after, and Julia takes the count at startup
  because it cannot be changed later
- JSON serialized by JSON3 from a struct, so the field order is fixed
- Compression is hand written with CodecZlib, because HTTP.jl ships no
  compression middleware. This is what the entry declares `tuned` for. The
  compressors are pooled, one per thread, since `deflateInit` allocates a few
  hundred KB
- Responses set Content-Length, which is what puts HTTP.jl on its fixed length
  path where head and body leave in a single write
- json-tls is served by wrapping a `TCP.Listener` in a `TLS.Listener` and handing
  that to `HTTP.listen!`. Reseau is HTTP.jl's own transport, so this is the stack
  the package already ships rather than a second one added for the profile; it is
  a direct dependency here only because HTTP.jl does not re-export it
- `listen!` for TLS and blocking `listen` for plaintext, so both accept loops feed
  the same `:interactive` pool and 8081 is served by every thread rather than by
  whichever one bound it
- ALPN answers `http/1.1` and nothing else: 8081 is the HTTP/1.1 port and h2 lives
  on 8443, so an h2-capable client must never be offered the upgrade here
- A missing `/certs` is not fatal — the TLS listener just stays down. `validate.sh`
  mounts the directory only for entries subscribed to a TLS test, so the plaintext
  profiles have to start without it
- Packages are precompiled in the build stage and the package image is built
  from a workload that serves real requests, so the first request does not pay
  for the Julia compiler
