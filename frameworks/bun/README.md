# bun

Bun's own HTTP server, `Bun.serve`, with no framework on top. One process per CPU, all sharing
every port through `reusePort`. The same routes serve HTTP/1.1, HTTP/2 and HTTP/3 - the protocol
is a flag on the listener, not a second implementation.

## Stack

- **Language:** TypeScript
- **Runtime:** [Bun](https://github.com/oven-sh/bun) 1.4.1
- **Framework:** none, `Bun.serve` from the standard library
- **Build:** Single stage on `oven/bun:${BUN_VERSION}`, `BUN_VERSION` a build arg defaulting to `1.4.1`

## Listeners

| Port | Transport | Protocol | Profiles |
|------|-----------|----------|----------|
| 8080 | TCP | HTTP/1.1 | `baseline`, `pipelined`, `limited-conn`, `json-comp`, `async`, `latency-*`, `async-db`, `fortunes` |
| 8081 | TLS | HTTP/1.1 only, no ALPN negotiated | `json-tls`, `static-tls`, `8gbit` |
| 8082 | TCP | h2c on the HTTP/2 preface (prior knowledge) via `http2: true` | `baseline-h2c`, `json-h2c` |
| 8443/tcp | TLS | h2 via ALPN (`http2: true`), HTTP/1.1 for a client that does not offer it; every response carries `Alt-Svc: h3` | `baseline-h2`, `static-h2` |
| 8443/udp | QUIC | HTTP/3 via `http3: true`, Bun's own lsquic | `baseline-h3`, `static-h3` |

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | Sums query parameter values |
| `/json/:count` | GET | Serializes a slice of the dataset, gzipped when the client accepts it |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/:name` | GET | Serves one of the 20 files from `/data/static`, read off disk per request |
| `/async-db` | GET | Postgres range query over `items`, `min`/`max`/`limit` |
| `/crud/items` | GET/POST | Paginated list by category; POST upserts |
| `/crud/items/:id` | GET/PUT | Cache-aside read through Redis; PUT updates and invalidates |
| `/fortunes` | GET | Postgres rows plus one runtime row, sorted, HTML-escaped into a table |

Both TLS listeners are only opened when the harness mounts `/certs`.

## Notes

- Postgres and Redis are `Bun.SQL` and `Bun.RedisClient`, both shipped with the runtime, so the
  database profiles cost this entry no dependency.

- Bun was on the board as a WebSocket echo server only. This entry is the plain HTTP floor of the
  runtime itself, so a Bun framework entry can be read against it.
- Scaling is not the cluster module: every process calls `Bun.serve` with `reusePort`, binds the
  same port and lets the kernel spread the accepts. The process count comes from `nproc`, lowered
  to the cgroup quota when there is one.
- Routing is `Bun.serve`'s own declarative `routes` table: it matches method and path and fills in
  `req.params`, so what gets measured is Bun's router rather than a hand-rolled one. Only the query
  string is pulled out of `req.url` by hand, since the router does not hand it over.
- `Bun.serve` does no content negotiation, so `/json` gzips its own body when `Accept-Encoding`
  asks for it, and sends it uncompressed otherwise. The `json-h2c` load generator does not ask,
  so that profile measures the plain path.
- `http2: true` and `http3: true` are experimental in Bun. The h2 flag shipped in 1.4.1
  ([oven-sh/bun#40137](https://github.com/oven-sh/bun/pull/40137)); on 1.4.0 it is ignored rather
  than rejected and the listener answers HTTP/1.1, which validation reports as such. The h3 flag
  ([oven-sh/bun#29768](https://github.com/oven-sh/bun/pull/29768)) shipped back in 1.3.14. Bun's 1.4
  release notes list the current h3 limits - 0-RTT resumption disabled, `server.upgrade()` false
  over h3, `unix:` sockets skipping the H3 listener - none of which the profiles touch.
- :8081 deliberately has no `http2` flag: `json-tls`, `static-tls` and `8gbit` are measured over
  HTTP/1.1, and with the flag Bun would hand h2 to any client whose ALPN offers it. Without it Bun
  negotiates no ALPN at all there, which is what the posture probe expects.
- Each listener past :8080 is wrapped so a bind failure costs only its own profiles. A stale process
  on :8082 or :8443 - reachable, since the harness runs this container on `--network host` - would
  otherwise throw past the top level and take the twelve HTTP/1.1 profiles down with it.
- :8082 answers an HTTP/1.1 request as well as h2c, which the baseline-h2c rules permit outright
  ("Dual-serving h1 on the same port is allowed"). Neither driver can take that path by accident:
  the benchmark runs `h2load -p h2c` and validation probes with `--http2-prior-knowledge`. Bun 1.4.1
  would also accept `http1: false` on this listener, which answers 505 to an HTTP/1.1 client; it is
  left off because the profile does not ask for it.
- Every worker binds udp/8443 through the same `reusePort`, and the kernel spreads QUIC connections
  by 4-tuple. That holds here because the load generator never migrates a connection mid-run.
  Measured rather than assumed: four concurrent workers each bind all four listeners including
  udp/8443, and h3 requests from separate clients are answered by all four PIDs.
- The h3 profiles offer 64 connections against one worker per core, so on a 64-core cpuset a good
  share of the workers draw no connection at all. The HTTP/3 number is therefore noisier than the
  h2 ones, which spread 256-1024 connections over the same workers.
- `/echo` reads the body with `req.arrayBuffer()`, which finishes the read whatever the framing is,
  so a chunked request works and the reply gets its Content-Length from the buffer. The 8gbit
  profile it serves is 10 KB up and the same 10 KB back; validation also posts 1 B, 1 KB, 100 KB
  and an empty body, chunked as well as with a Content-Length.
