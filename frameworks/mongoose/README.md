# Mongoose

[Mongoose](https://github.com/cesanta/mongoose) — Cesanta's embedded networking library. Two files
(`mongoose.c` / `mongoose.h`), no build system, no runtime dependencies beyond libc, and an HTTP/1.1
server, a WebSocket implementation and a TLS layer inside them. It is normally embedded in firmware,
which is what makes it interesting here: the same event loop that runs on a microcontroller is being
asked to serve 4,096 keep-alive connections on 64 threads.

Everything on the wire is Mongoose's. This entry contributes handlers, a fork, and one `setsockopt`.

## Stack

- **Language:** C (gcc 14, `-O3 -march=native -flto`)
- **Engine:** Mongoose 7.23, `epoll` (`MG_ENABLE_EPOLL=1`)
- **TLS:** OpenSSL backend (`MG_TLS=MG_TLS_OPENSSL`)
- **Build:** `ubuntu:24.04` → `ubuntu:24.04`

## Architecture

Mongoose's `struct mg_mgr` is a single-threaded event loop and is not thread-safe, so the only way
to use more than one core is more than one of them. The entry forks one process per CPU in the
container's affinity mask and pins each to its CPU. `--cpuset-cpus` is what the profiles set and it
lands in that mask, so `baseline` gets 64 workers and `latency-500k-8cpu` gets 8 without anything
being configured here. `MONGOOSE_WORKERS` overrides the count.

Each worker opens its own `:8080` and `:8081` listeners and lets the kernel balance accepts across
them. Mongoose sets `SO_REUSEADDR` on a listening socket and stops there, which is not enough for
N processes to bind the same port, so `main.c` defines `socket(2)` — a definition in the executable
wins the dynamic linker's lookup over libc's, so Mongoose's own call lands there and gets
`SO_REUSEPORT` set on the way out. The flag is only honoured while a listener is being opened.
This is in place of patching a pinned upstream tarball; it survives a version bump.

`/delay/{ms}` is the one route that cannot answer immediately. Rather than a timer per request —
one allocation per request, and a dangling pointer every time a client hangs up mid-wait — the
deadline is parked in the 32 bytes Mongoose reserves per connection (`c->data`) and checked in
`MG_EV_POLL`, which already visits every connection once per loop. The loop's epoll timeout drops
from 100 ms to 1 ms while any delay is outstanding, so an idle worker still blocks for 100 ms at a
time — which is what `latency-10k` measures.

## Endpoints

| Endpoint | Method | Port | Description |
|----------|--------|------|-------------|
| `/baseline11` | GET | 8080 | Sum of the `a` and `b` query parameters |
| `/baseline11` | POST | 8080 | Query parameters plus the body (Content-Length and chunked) |
| `/delay/{ms}` | GET | 8080 | Waits `{ms}` milliseconds, then echoes the number |
| `/ws` | GET | 8080 | WebSocket upgrade; echoes text and binary frames |
| `/json/{count}?m={mult}` | GET | 8081 | First `{count}` dataset items, `total = price × quantity × m` |
| `/echo` | POST | 8081 | Echoes the request body verbatim |
| `/static/*` | GET | 8081 | The 20 files under `/data/static`, via `mg_http_serve_dir` |

## Notes

- **Static files** go through `mg_http_serve_dir`, which reads `/data/static` on every request —
  there is no cache to go stale. When the client sends `Accept-Encoding: gzip`, Mongoose's own
  `mg_http_serve_file` opens `<path>.gz` if it exists and answers with `Content-Encoding: gzip`;
  15 of the 20 files have a `.gz` twin on disk, so that is what they are served as. Mongoose does
  not do Brotli, and it does not compress anything itself. The only configuration here is a mime
  override for `.woff2`, which Mongoose's built-in table does not carry.
- **JSON** is serialized per request through Mongoose's own `%M` printer, straight into the
  connection's send buffer. `/data/dataset.json` is parsed once before the fork, so the 50 items are
  shared copy-on-write; `tags` is re-serialized at load into a compact array so responses do not
  carry the source document's indentation.
- **TLS** uses the OpenSSL backend rather than Mongoose's built-in stack. The harness mounts an
  RSA-2048 certificate and every handshake is signed with it, and the built-in implementation would
  also be doing bulk AES in portable C. Note that Mongoose builds one `SSL_CTX` per accepted
  connection — the certificate and key are read once at startup, but they are parsed per
  connection. That is the library's design, and it is a real cost during the connection ramp.
- **Logging** is compiled out (`MG_ENABLE_LOG=0`): `MG_VERBOSE` otherwise calls `mg_log_prefix()`
  once per connection per poll iteration. Build with `--build-arg MG_LOG=1` to get it back.
- **No HTTP/2, HTTP/3 or gRPC.** Mongoose implements HTTP/1.1 and WebSocket only, so those profiles
  are not subscribed.
