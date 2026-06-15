# ioxide

[ioxide](https://github.com/MDA2AV/ioxide) - a shared-nothing io_uring runtime for .NET -
consumed as its published NuGet packages (`ioxide`, `ioxide.pg`, `ioxide.file` 0.0.5), not
vendored. One ring per reactor thread: SO_REUSEPORT + multishot accept, multishot recv into a
provided buffer ring, inline IValueTaskSource continuations, raw-syscall io_uring (no liburing).

The HTTP/1.1 handler (request line, headers, Content-Length + chunked bodies, keep-alive,
pipelining, fragmented reads) is hand-written on the raw recv/send API - no HTTP framework.

## Profiles

| profile | how |
|---|---|
| baseline / pipelined / limited-conn | hand-rolled parser with a per-connection carry buffer |
| json / json-comp | dataset parsed to a model at startup, serialized field-by-field per request; json-comp brotli-encodes per request when the client sends `Accept-Encoding: br` |
| json-tls | json over TLS on :8081 via `ioxide.tls` (kTLS TX offload) when `/certs` is mounted |
| static | `ioxide.file` baked identity snapshots (full response precomputed in native memory). Content negotiation is HTTP, so it lives in the entry (`Precompressed.cs`): `.br`/`.gz` siblings are baked once at startup with the base content-type + `Content-Encoding` + `Vary`, and chosen per request by `Accept-Encoding` (br > gzip > identity) |
| upload | POST body drained against Content-Length, byte count returned |
| async-db | `ioxide.pg`: pooled ring-native Postgres connections per reactor, SCRAM-SHA-256, rows streamed straight from the driver's receive buffer into the response |
| crud | `ioxide.pg` for list/get/upsert/update + `ioxide.redis` cache-aside on single-item reads (X-Cache MISS/HIT, 1s TTL, invalidated on PUT). Redis is shared across reactors, so reads stay consistent under shared-nothing |
| api-4 / api-16 | the baseline + json + async-db endpoints under a CPU budget; `Environment.ProcessorCount` honors the cpuset, so reactor count matches the budget (api-4 = 4 reactors on 2 SMT cores, api-16 = 16 on 8) |

## Env

- `IOXIDE_REACTORS` (default: processor count), `IOXIDE_PORT` (8080)
- `IOXIDE_DATASET` (/data/dataset.json), `IOXIDE_STATIC` (/data/static)
- `DATABASE_URL`, `DATABASE_MAX_CONN` (Postgres; pool per reactor = max_conn / reactors, clamped 1..8)
- `REDIS_URL` (crud cache-aside sidecar)
