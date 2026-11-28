# nifra-bun

Nifra's typed router and middleware running on Bun through `app.listen()`, Nifra's own Bun server
entry point. One process per available core binds the same ports with `reusePort`.

## Stack

- **Language:** TypeScript
- **Runtime:** Bun 1.4.4
- **Framework:** [Nifra](https://nifra.dev/) 5.16.0
- **Server:** `app.listen()` from `@nifrajs/core`, on Bun's native HTTP server
- **Build:** `oven/bun:1.4.4`; Bun runs TypeScript directly

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/delay/:ms` | GET | Waits for the requested delay without blocking the event loop |
| `/baseline11` | GET/POST | Sums query parameters, plus the POST body |
| `/baseline2` | GET | Sums query parameters for the HTTP/2-shaped baseline route |
| `/json/:count` | GET | Serializes a slice of the mounted dataset and computes `total` with `m` |
| `/echo` | POST | Returns the request body byte-for-byte |
| `/static/:file` | GET | Serves files from the mounted static directory through `serveStatic` |
| `/async-db` | GET | Parameterized Postgres range query over `items` |
| `/fortunes` | GET | Queries Postgres and renders the result with Handlebars, including HTML escaping |

## Notes

- `compression()` is Nifra's official gzip middleware, applied to the `/json` group only. It
  negotiates compression per request, so a response is compressed only when the client sends
  `Accept-Encoding: gzip` and the body crosses the middleware threshold.
- Static files go through Nifra's `serveStatic` handler, passed to `listen()` as `static`. The
  benchmark's mounted directory remains the source of truth, including its staleness probes.
- Each process creates its own Postgres pool and divides `DATABASE_MAX_CONN` across the processes.
- Each process creates its own Postgres pool and divides `DATABASE_MAX_CONN` across the
  processes, so the entry does not multiply the sidecar's connection budget.
- The entry subscribes only to the HTTP/1.1 profiles it implements. HTTP/2, HTTP/3, WebSocket,
  gRPC, and gateway profiles are intentionally left out of `meta.json`.
