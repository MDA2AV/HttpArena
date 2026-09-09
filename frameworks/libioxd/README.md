# libioxd

[libioxd](https://github.com/MDA2AV/libioxd) is an HTTP/1.1 server library in C23 on a
thread-per-core `io_uring` runtime. Each connection runs as a stackful coroutine: the library
parses, routes and frames, and anything that has to wait - a body read, a timer, a send - parks
the connection on the ring and hands the worker to its other connections. A handler reads as
linear code with no state machine. Manual: https://mda2av.github.io/libioxd/

## Stack

- **Language:** C23 (gcc 14, `-O3 -march=native -flto`)
- **Engine:** raw `io_uring` syscalls, no liburing. Multishot accept and multishot recv over
  per-worker provided buffer rings; `SINGLE_ISSUER | DEFER_TASKRUN | NO_SQARRAY`; sockets in the
  registered file table.
- **Architecture:** thread-per-core, shared-nothing. One ring, one `SO_REUSEPORT` listener per port
  and one buffer ring per worker; workers pin to the CPUs in the process affinity mask.
- **Parser:** [picohttpparser](https://github.com/h2o/picohttpparser) for the request line and
  headers; the library decodes Content-Length and chunked bodies on demand.
- **TLS:** TLS 1.3 only. OpenSSL runs the handshake over the connection; the record layer is the
  kernel's (kTLS, transmit and receive), so a handler writes plaintext and the ring sends it.
- **JSON:** the dataset is parsed once at startup with [cJSON](https://github.com/DaveGamble/cJSON);
  each reply is serialized by the library's forward-only JSON writer straight into the reply slab.
- **Timer:** `/delay` waits on the ring's own timeout (`IORING_OP_TIMEOUT`), one entry per request.
- **Static files:** opened, sized and read from disk on every request - nothing is cached, so a
  file replaced on disk is served at once. A `.br` or `.gz` twin beside the file is served when
  `Accept-Encoding` takes the coding, with the base type and the matching `Content-Encoding`.

## Build

The Dockerfile fetches libioxd from its repo at a pinned commit (`LIBIOXD_VERSION`), builds the
static library in-container tuned for the benchmark CPU, and links the handlers below against it -
so this entry holds only the handlers, not the library source. To move to a newer libioxd, bump
`LIBIOXD_VERSION` in the Dockerfile.

Ports: `8080` plain, `8081` TLS. The certificate pair comes from `/certs/server.crt` and
`/certs/server.key` (or `TLS_CERT` / `TLS_KEY`); kTLS needs the `tls` kernel module on the host
(`modprobe tls`) - without it the TLS port refuses every handshake and `8080` still serves.
The dataset is `/data/dataset.json` (`DATASET_PATH`), the static root `/data/static` (`STATIC_ROOT`).

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums the query parameter values |
| `/baseline11` | POST | Sums the query parameters plus the request body (Content-Length and chunked) |
| `/delay/{ms}` | GET | Waits `ms` milliseconds on the ring, answers `ms` as `text/plain` |
| `/json/{count}?m=N` | GET | The first `count` dataset items with `total = price × quantity × N`, as `{items, count}` |
| `/echo` | POST | The request body back, byte for byte (`:8081`) |
| `/static/{file}` | GET | A file from `/data/static`, or its pre-compressed twin (`:8081`) |

Library: https://github.com/MDA2AV/libioxd
