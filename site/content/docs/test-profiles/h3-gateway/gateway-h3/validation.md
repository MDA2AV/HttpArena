---
title: Validation
---

The Gateway-H3 validation flow reuses the same checks as [Gateway-64](../../h2-gateway/gateway-64/validation/) — same endpoints, same expected responses, same anti-cheat probes. The only differences:

- A separate `compose.gateway-h3.yml` is built and started (instead of `compose.gateway.yml`).
- Endpoint probes go to the same proxy on port 8443 but use `curl --http2` rather than `curl --http3`.

Why curl `--http2` for an h3 test? Most curl builds don't ship HTTP/3 support by default, and requiring QUIC-enabled curl would break `validate.sh` on contributors' machines. The compromise: h3-capable proxies (Caddy, nginx-quic, Envoy, HAProxy) advertise h2 on the same port anyway, so curl can reach the same endpoints for **correctness** validation. The **h3-specific** path is exercised at benchmark time by `h2load-h3` with `--alpn-list=h3` — if h3 is broken, the benchmark will show 0 req/s and you'll see it immediately.

## Checks performed

Same set as [Gateway-64 validation](../../h2-gateway/gateway-64/validation/):

1. HTTPS port responds within 30 seconds
2. HTTP/2 protocol negotiation (as a proxy-health sanity check)
3. `/static/reset.css` — `Content-Type: text/css`
4. `/static/app.js` — `Content-Type: application/javascript`
5. `/static/app.js` — non-zero response body
6. `/static/nonexistent.txt` — HTTP 404
7. `/json/50` — returns 50 items with computed `total` field per item
8. `/json/50` — `Content-Type: application/json`
9. `/async-db?min=10&max=50&limit=50` — returns 1–50 items with nested `rating`, `tags`, boolean `active`
10. `/async-db` — `Content-Type: application/json`
11. `/async-db?min=9999&max=9999` — returns `count: 0` (anti-cheat)
12. `/baseline2?a=13&b=42` — returns `55`
13. `/baseline2?a=<random>&b=<random>` — returns correct sum (anti-cheat)

## What validation does NOT check

- **HTTP/3 protocol negotiation at the edge** — requires QUIC-capable curl, not available in most builds. Covered implicitly by the benchmark: if the proxy can't speak h3, `h2load-h3` will report 0 req/s.
- **QUIC connection migration, 0-RTT, or specific QUIC features** — out of scope for correctness validation.
- **Precompressed sidecar serving** — validated at runtime by the benchmark's `Accept-Encoding: br;q=1, gzip;q=0.8` request header. If the proxy serves the raw file instead of the `.br` / `.gz` sidecar, response size will be larger and bandwidth numbers will reflect that.
