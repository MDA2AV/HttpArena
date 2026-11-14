# mipyre — HTTP Arena submission

mipyre is a Python web framework with a Rust core: hyper + tokio + rustls +
mimalloc, with one pinned thread per physical core and a PEP 684
sub-interpreter on each, so Python handlers run on every core at once. This
submission exposes every Arena endpoint with standard mipyre decorators — no
special harness-only glue.

## Feature posture

| Profile | mipyre feature |
|---|---|
| baseline / pipelined / limited-conn | sub-interpreter route per TPC thread, `SO_REUSEPORT` listener per thread; `/pipeline` is an ordinary `@app.get` route |
| json-comp | Rust-side serialization of the returned dict; `app.enable_compression()`, at its defaults, negotiates `Accept-Encoding` |
| json-tls | rustls, ALPN `h2,http/1.1` |
| baseline-h2 / static-h2 | the TLS listener on :8443; HTTP/2 on negotiated ALPN |
| baseline-h2c / json-h2c | port 8082 is one more plain listener; a plain listener answers h2 prior knowledge |
| 8gbit | plain sub-interpreter route: the engine reads the body (Content-Length or chunked), the handler returns `Response(req.body)` |
| static-tls / static-h2 | `app.static(..., precompressed=True)`: `.br` / `.gz` twins on disk, cache that follows the disk |
| async | `async def` route + `asyncio.sleep` on its worker's asyncio loop |
| async-db / fortunes | `mipyre.db.PgPool` (sqlx) on the run's DB runtime; a worker waits with its GIL released. fortunes renders `templates/fortunes.html` with Jinja2 |
| unary-grpc / unary-grpc-tls | `@app.unary_unary`: `GetSum` is a Python handler, its messages decoded and encoded by `protobuf` (`benchmark_pb2.py` is protoc's from `benchmark.proto`) |
| latency-500k-8cpu | one TPC thread per physical core of the cpuset (4 on `0-3,64-67`) |
| echo-ws | `@app.websocket("/ws")`: a `def` called once per message returns it; **not subscribed** (`meta.json`) |

## Build (local)

The image installs the released wheel from PyPI (`mipyre==4.1.0`, cp314
manylinux x86_64); there is no source tree or Rust toolchain in the build.

```bash
docker build -t httparena-mipyre frameworks/mipyre
```

## Design notes

`launcher.py` starts one process serving every port, and gives the engine its
settings as `MIPYRE_*` variables (threads, host, ports, TLS files). The engine
refuses a `MIPYRE_*` name it does not read, so a renamed setting stops the
start instead of running on defaults. It sizes the server to one thread per
**physical** core of the container's cpuset (32 on the Arena's `0-31,64-95`):
two threads on SMT siblings of one core run the same code path and contend for
its L1/L2.

The Postgres pool belongs to the server run, not to a Python interpreter:
every worker's `PgPool.connect()` binds to the run's one pool, so a 32-thread
deployment doesn't multiply connection count.
