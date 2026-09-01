# Varnish

Varnish Cache HTTP accelerator with native TLS/H2 termination (`varnishd -A`),
`vmod-fileserver` serving `/static/*` directly from Varnish's own cache, and a
custom vmod (`vmod_httparena`, written in Rust with
[varnish-rs](https://github.com/varnish-rs/varnish-rs)) computing the
`/baseline11`/`/baseline2` sum entirely inside `varnishd` — no separate
backend process at all.

## Stack

- **Engine:** varnishd 9.0 (native TLS via `-A`, HTTP/2 via `feature=+http2`)
- **Static files:** `vmod-fileserver`, rooted at `/data`, using `/etc/mime.types`
  for correct `Content-Type` per extension — installed via the Debian
  `media-types` package in the build stage and copied into the final image
  (the base image ships no `/etc/mime.types` of its own). Older
  `vmod-fileserver` versions hard-errored on the first duplicate extension in
  a MIME file (and `media-types`' comprehensive file has several), silently
  breaking `Content-Type` for every file via `.ok()`; the currently-packaged
  version no longer errors on duplicates (last matching line wins instead).
- **Dynamic logic:** `vmod_httparena` (`vmod/`), a small Rust vmod built
  against `varnish-dev` headers matching the base image, computing the sum
  and reading the POST body directly via `Ctx::req_body` (varnish-rs 0.7.2+)

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text), answered directly by Varnish via `vcl_synth` |
| `/baseline11` | GET | Sums query parameter values, computed by `httparena.baseline_sum()` |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Same sum logic, over HTTP/2 + TLS (port 8443) |
| `/baseline2` (h2c) | GET | Same sum logic, over cleartext HTTP/2 prior-knowledge (port 8082) |
| `/static/{filename}` | GET | Served by `vmod-fileserver` from `/data/static`, cached by Varnish |
| `/static/{filename}` (TLS) | GET | Same fileserver route, over HTTP/1.1 + TLS (port 8081) |
| `/upload` | POST | Reads and discards the body, computed by `httparena.upload_count()`; responds with the byte count |

## Listeners

| Port | Protocol | Used by |
|------|----------|---------|
| 8080 | HTTP/1.1 (cleartext) | `baseline`, `pipelined`, `limited-conn`, `upload`, `static` |
| 8081 | HTTP/1.1 + TLS | `static-tls` |
| 8082 | HTTP/2 (cleartext, prior-knowledge) | `baseline-h2c` |
| 8443 | HTTP/2 + TLS | `baseline-h2`, `static-h2` |

## Notes

- TLS/H2 is terminated natively by `varnishd` itself via `-A /etc/varnish/tls.conf`
  (no Hitch/nginx in front) — no HTTP/3/QUIC support, so `baseline-h3`/`static-h3`
  are out of scope.
- `/static/*` responses are real Varnish cache objects (served from memory on
  repeat requests), not a workaround — this is Varnish's actual value proposition.
- `/baseline11`/`/baseline2` are always answered synthetically (`vcl_recv`
  returns `synth(200)`), so there's no backend fetch or caching to reason
  about for these routes — each request is computed fresh.
- POST bodies are read directly by the vmod via `Ctx::req_body` — no
  `std.cache_req_body()` needed, since nothing downstream (there's no real
  backend) needs to read the same body a second time.
- `/upload` reads the body through a counting `Write` sink that never buffers
  it, so a 20 MB upload costs no allocation — `httparena.upload_count()`
  ignores `req_body`'s own `Result` so a short/truncated body still reports
  the bytes actually seen instead of echoing the declared `Content-Length`.
- The vmod is built from source in a throwaway Docker build stage (Rust
  toolchain + `varnish-dev` headers matching the base image's exact version);
  only the compiled `.so` (and `/etc/mime.types`) is copied into the final
  image, keeping the shipped image free of the Rust toolchain and apt cache.
