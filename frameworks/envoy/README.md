# envoy

Envoy proxy acting as a standalone HTTP/1.1 server. The `/baseline11` dynamic
endpoint is handled entirely inside an inline Lua HTTP filter — no upstream
cluster is contacted for that route. Static files under `/static/<name>` are
served using one `direct_response` route per file, with `body.filename`
pointing at `/data/static/<name>` (the mount used by every framework in this
repo).

## Stack

- **Engine:** envoyproxy/envoy:v1.30-latest (Docker image)
- **Language:** C++ (Envoy core); inline Lua for the dynamic handler
- **Config:** single `envoy.yaml` bootstrap, self-contained (no external files)

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter integer values |
| `/baseline11` | POST | Sums query parameters + parsed request body |
| `/static/{filename}` | GET | Streams a file from `/data/static/` |

## Notes

- Envoy has no native static file server, so each static asset is enumerated
  as its own `direct_response` route. `body.filename` on `direct_response`
  requires Envoy **v1.19+** and streams the mounted file at request time.
- The Lua filter short-circuits the request with `request_handle:respond(...)`,
  so the `local_cluster` defined in the config is never actually dialed.
- `--concurrency 0` tells Envoy to auto-size worker threads to the CPU count.
