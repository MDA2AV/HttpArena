# veil-api (Rust)

An application written with the API library of [veil](https://github.com/aofusa/veil-proxy) (the
`veil-proxy` crate with the `api` feature). veil serves HTTP/1.1, HTTP/2, HTTP/3 and WebSocket on its own async
runtime (no tokio, no hyper); this entry uses the `full-container` feature set (epoll readiness reactor).

## Endpoints

| Endpoint | Implementation |
|---|---|
| `GET`/`POST /baseline11`, `GET /baseline2`, `GET /pipeline` | `#[veil::route]` handlers; `a` and `b` are bound from the query, the POST body is `req.body()` |
| `GET /json/{count}?m=` | `#[veil::route]` with a path parameter and an optional query parameter; the response is `Response::json` (serde_json, per request) from the dataset read at startup |
| `GET /delay/{ms}` | `async` handler awaiting `veil::runtime::time::sleep` |
| `POST /echo` | returns the request body (`Response::bytes`) |
| `GET /ws` | `WebSocketUpgrade::on_upgrade`, echoing text and binary messages |
| `benchmark.BenchmarkService` (gRPC) | the trait generated from `proto/benchmark.proto` by `veil-build` (prost), registered with `add_benchmark_service` |
| `/static/*` | `App::serve_dir` (veil's File backend: br/gzip compressed on the fly on HTTP/1.1, HTTP/2 and HTTP/3, uncompressed responses with sendfile on HTTP/1.1, caches that follow the disk) |

## Configuration

`veil.toml` holds the settings of veil's production guide for API applications
(`docs/guide/library-production.md`): JSON application log, no access log, OpenAPI off, response compression
on (`[api] compression`: br or gzip by `Accept-Encoding`, for JSON and text of 256 bytes or more), and the static
caches following the disk (`watch`). The four HttpArena listeners are `[[listener]]` entries, served by **one
process**. Worker threads default to the CPUs the container may use.

## Completeness

- routing: `#[veil::route(path = "/json/{count}", method = "GET")]` matches method and path with parameters.
- middleware: tower `Layer`s around the app or a route prefix (`App::layer`, `App::layer_on`, `App::wrap_on`), able to run before and
  after the handler and to answer early.
- request: path, query and headers are bound by the macro; the body is available buffered (`req.body()`,
  `Json<T>`, forms, multipart) or as a stream (`streaming = true`).
- response: `Response::json`, `Response::bytes`, streams and files, with status and headers in one value.
