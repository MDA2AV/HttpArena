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
- Packages are precompiled in the build stage and the package image is built
  from a workload that serves real requests, so the first request does not pay
  for the Julia compiler
