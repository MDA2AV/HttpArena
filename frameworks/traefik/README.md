# traefik

Traefik acting as a standalone HTTP/1.1 server. Traefik is primarily a reverse
proxy — it has no native way to produce computed responses or serve files off
disk — so the benchmark contract is implemented via a **local Traefik plugin**
written in Go and interpreted at runtime by Traefik's embedded Yaegi engine.

## Stack

- **Engine:** traefik:v3.1 (Docker image)
- **Language:** Go (interpreted by Yaegi at runtime — no pre-compilation)
- **Config:** `traefik.yml` (static) + `dynamic.yml` (routers/middlewares)
- **Plugin:** `plugin/httparena/` — stdlib-only middleware, mounted inside
  the container at `/plugins-local/src/github.com/httparena/traefik-httparena/`
  (Traefik's required local-plugin directory layout).

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter integer values |
| `/baseline11` | POST | Sums query parameters + parsed request body |
| `/static/{filename}` | GET | Streams a file from `/data/static/` |

## Notes

- Because the plugin is **interpreted** by Yaegi rather than compiled, per-
  request overhead is materially higher than the other Go-based entries
  (caddy, go-fasthttp) that compile native handlers. Expect this entry to
  rank at or near the bottom of the infrastructure pool. That is the honest
  reality of the Yaegi plugin surface — included for completeness, not
  because it would win.
- The plugin is pure stdlib. Yaegi's coverage of third-party packages is
  patchy, so hand-rolled content-type detection is used instead of pulling
  the `mime` package.
- A catch-all router wires every request through the plugin middleware;
  the declared upstream service is a stub (127.0.0.1:1) that the plugin
  never actually calls — it short-circuits `/baseline11` and `/static/*`
  with `WriteHeader` + `io.Copy` and returns without invoking `next`.
