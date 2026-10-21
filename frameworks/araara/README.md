# araara

[araara](https://araara.ml) is a web stack for OCaml 5 built on
[hcs](https://tangled.org/gdiazlo.tngl.sh/hcs), an Eio-based HTTP/1.1, HTTP/2,
WebSocket and gRPC server. This entry runs in **standard** mode: documented
framework APIs and the settings hcs's own deployment guide recommends, nothing
tuned for the benchmark.

```sh
docker build -t httparena-araara frameworks/araara
./scripts/validate.sh araara
```

## What is built

The image installs the released packages `hcs`, `simdjsont`, `repodb` and
`ocaml-protoc` through opam (OCaml 5.4, versions pinned in the `Dockerfile`) and compiles
`server/arena.ml` with dune's release profile. The application is the only
code in this directory; the gRPC codecs are generated at build time from
HttpArena's `benchmark.proto`.

## Deployment

The process follows hcs's deployment guide (`docs/guides/deployment.md` in
the hcs repository): one single-domain worker process per CPU the container
may use (`Domain.recommended_domain_count`, which follows the cpuset), every
worker binding all four listeners with `reuse_port = true`. The garbage
collector keeps the runtime's defaults, and nothing else departs from
`Hcs.Server.default_config`. The parent process only supervises; if a worker
exits, the process exits.

| Port | Protocol | Profiles |
|------|----------|----------|
| 8080 | HTTP/1.1, h2c (prior knowledge), WebSocket | baseline, pipelined, limited-conn, async, latency-*, json-comp, async-db, unary-grpc, echo-ws* |
| 8081 | TLS, ALPN `http/1.1` | json-tls, 8gbit, static-tls |
| 8082 | h2c (prior knowledge) | baseline-h2c, json-h2c |
| 8443 | TLS, ALPN `h2`, `http/1.1` | baseline-h2, static-h2, unary-grpc-tls |

## Endpoints

- `/baseline11`, `/baseline2`, `/pipeline`: `Hcs.Router` routes with
  `Hcs.Request.query_int_or` and `Hcs.Request.body`.
- `/json/{count}?m=N`: simdjsont codecs serialize the slice on every request;
  `Hcs.Plug.Compress` (the framework's compression plug, defaults: gzip
  level 6) negotiates the coding from `Accept-Encoding`. hcs does not ship
  brotli.
- `/delay/{ms}`: the handler's fiber sleeps on the Eio clock; the worker keeps
  serving its other connections.
- `/echo`: the request body, read through the framework (Content-Length or
  chunked), is returned as the response body.
- `/static/*`: `Hcs.Plug.Static.server`, hcs's static file handler, with its
  `precompressed` option. The handler stats the file on every request and
  serves it from its own cache while the size, modification time and inode
  are unchanged, so a replaced file is served from the next response on; with
  `precompressed` it serves the on-disk `.br` / `.gz` twin a client accepts,
  with the original `Content-Type` and the matching `Content-Encoding`. The
  entry mounts the harness's `/data` directory as the root, so
  `/static/<file>` is `/data/static/<file>`.
- `/async-db`: repodb's typed query builder and `Repo.all_query`. The
  container's connection allowance (`DATABASE_MAX_CONN`) is split across the
  worker processes. repodb's Postgres driver is synchronous libpq, so each
  query runs on a system thread while the fiber waits; a semaphore bounds the
  threads by the pool size. An unavailable database answers
  `{"items":[],"count":0}`.
- `benchmark.BenchmarkService/GetSum`: `Hcs.Grpc.Server` with the
  ocaml-protoc codecs, mounted as a route on 8080 (h2c) and 8443 (TLS).
- `/ws`: `Hcs.Websocket.recv_message` / `send_text` echo loop. hcs writes
  the replies to frames that arrived in one read together.

## Completeness

Routing, middleware and request are done by hcs. Response is declared `false`
because `Hcs.Response.json` takes an already serialized string; the handler
calls the JSON encoder itself.
