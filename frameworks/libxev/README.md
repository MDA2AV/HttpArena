# libxev

HTTP/1.1 baseline server on [libxev](https://github.com/mitchellh/libxev) — Mitchell Hashimoto's
cross-platform event loop for Zig, using its `io_uring` backend on Linux.

## Stack

- **Language:** Zig (0.16.0, `ReleaseFast`, `-Dcpu=native`)
- **Engine:** libxev event loop over `io_uring`. Callback-driven `xev.TCP` accept / read / write.
- **Architecture:** one forked worker per available CPU (from the process affinity mask), each with
  its own `xev.Loop` and its own `SO_REUSEPORT` listener so the kernel balances accepts.
- **Parser:** [picohttpparser](https://github.com/h2o/picohttpparser) via Zig C interop for the
  request line and headers, plus `phr_decode_chunked` for chunked bodies.

## Build

The Dockerfile installs Zig 0.16.0 and runs `zig build`, which fetches libxev pinned by url+hash in
`build.zig.zon` and compiles the server against it. picohttpparser is vendored. To move to a newer
libxev, `zig fetch --save` a new archive URL.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums the query parameter values |
| `/baseline11` | POST | Sums the query parameters plus the request body (Content-Length and chunked) |

## Notes

- The per-connection state machine accumulates across reads, so it is fragmentation-safe (the
  parser carries state across `recv`), and it decodes chunked bodies from a scratch copy.
- Keep-alive by default; `Connection: close` closes after the response is written.
- Requires `--security-opt seccomp=unconfined` (io_uring), which the harness adds for
  `"engine": "io_uring"` entries.
