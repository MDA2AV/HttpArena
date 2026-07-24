# pingora

Cloudflare's [Pingora](https://github.com/cloudflare/pingora) Rust HTTP framework, wrapped as a standalone HTTP/1.1 server for the HttpArena `infrastructure` suite.

## Stack

- **Language:** Rust, edition 2021
- **Crate:** `pingora` 0.8 with the `openssl` feature (required to link the core runtime; no TLS listener is opened).
- **Build:** Multi-stage, `rust:1.85-bookworm` build image, `debian:bookworm-slim` runtime.

## Why it looks like this

Pingora is a _library_, not a daemon. Unlike nginx/h2o, there's no ready-made binary: this entry is a thin main.rs that implements the `ServeHttp` trait (from `pingora::apps::http_app`) and registers it as a TCP listener on `0.0.0.0:8080` via `HttpServer::new_app` + `Service::add_tcp`. The proxy modules (`pingora-proxy`, `ProxyHttp`) are deliberately _not_ used — there is no upstream.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums integer query parameter values |
| `/baseline11` | POST | Sums query parameters + request body (body capped at 64 KiB) |
| `/static/{filename}` | GET | Serves preloaded static file |

## Notes

- **Static preloading.** `/data/static/*` is slurped into a `HashMap<String, Vec<u8>>` at startup (~20 small files). Content-Type is derived from the extension.
- **Thread count.** `ServerConf.threads` is set to `num_cpus::get()` before `Server::bootstrap()`. Pingora builds a work-stealing tokio runtime per service at that size.
- **Release profile.** `lto = "fat"`, `codegen-units = 1`, `opt-level = 3`, `strip = true`, `panic = "abort"`, compiled with `-C target-cpu=native`.
