# libioma

Minimal HTTP/1.1 framework in C on a thread-per-core `io_uring` runtime. Each connection runs as a
stackful coroutine: the framework parses, routes and serializes, and the flush suspends the
coroutine until io_uring reports the send complete — so a handler reads as linear code with no
state machine.

## Stack

- **Language:** C (GCC, `-O2 -march=native`)
- **Engine:** raw `io_uring` syscalls — no liburing. Multishot accept and multishot recv over
  per-worker provided buffer rings; `SINGLE_ISSUER | DEFER_TASKRUN | NO_SQARRAY`.
- **Architecture:** thread-per-core, shared-nothing. One ring, one `SO_REUSEPORT` listener and one
  buffer ring per worker; workers pin to the CPUs in the process affinity mask.
- **Parser:** [picohttpparser](https://github.com/h2o/picohttpparser) for the request line and
  headers, plus `phr_decode_chunked` for chunked bodies.
- **Response path:** heads built by `memcpy` of precomposed pieces plus a hand-rolled integer
  writer (no `snprintf`); small bodies inlined so a reply is one send.

## Build

The Dockerfile fetches libioma from its repo at a pinned commit (`LIBIOMA_VERSION`), builds the
static library in-container tuned for the benchmark CPU, and links the handler below against it —
so this entry holds only the handler, not the library source. To move to a newer libioma, bump
`LIBIOMA_VERSION` in the Dockerfile.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums the query parameter values |
| `/baseline11` | POST | Sums the query parameters plus the request body (Content-Length and chunked) |

Library: https://github.com/MDA2AV/libioma
