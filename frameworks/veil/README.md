# veil

[veil](https://github.com/aofusa/veil-proxy) is a reverse proxy and web server written in Rust on its own async
runtime (io_uring on Linux by default; this entry uses the published container image, which is the
`full-container` build with the epoll readiness reactor). This is an **infrastructure** entry: veil is configured,
not programmed.

## How the endpoints are answered

| Endpoint | Answered by |
|---|---|
| `/baseline11` (GET, POST with Content-Length or chunked), `/baseline2`, `/pipeline`, `/json/{count}?m=` | A Proxy-Wasm module (`filter/`, Rust, `wasm32-wasip1`) loaded into veil. It answers with `send_local_response`; the POST body is read in the request-body phase. The route is `type = "Respond"` with the module, so nothing is proxied. |
| `/static/*` | veil's File backend: br/gzip compressed on the fly on HTTP/1.1, HTTP/2 and HTTP/3 (`[route.compression]`, cached; precompressed siblings are not used), uncompressed responses with `sendfile(2)` on HTTP/1.1, `open_file_cache` + `static_file_cache` with `watch = true` (inotify), so replaced files are served at once. |

The dataset is read once by veil at startup (`[[wasm.modules]] data_files`) and handed to the module as a property;
the module parses it once per instance (`instance_reuse = true`) and **serializes the JSON response on every
request**. Nothing is cached between requests.

## Listeners (one process)

| Port | Listener |
|---|---|
| 8080 | HTTP/1.1 (h2c by prior knowledge also accepted) |
| 8081 | TLS, HTTP/1.1 only (no `h2` in ALPN) |
| 8082 | h2c |
| 8443 | TLS h2 + HTTP/1.1, and HTTP/3 (quiche) on UDP 8443 |

All four are `[[listener]]` entries in `veil.toml`, served by one veil process. Worker threads default to the CPUs
the container may use (affinity and cgroup quota). The access log is off; veil logs nothing per request.

## Security

The configuration keeps veil's container hardening on: privileges dropped to `nonroot`, seccomp filter mode and
Landlock limited to `/certs`, `/data` and `/etc/veil`.
