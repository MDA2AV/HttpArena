# fiber

Fiber web framework on fasthttp, with prefork for multi-core scaling.

## Stack

- **Language:** Go — `go 1.25.0` in go.mod, built with the 1.26 toolchain
- **Framework:** Fiber 3
- **Build:** `golang:1.26-alpine` -> `alpine:3.23` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums the `a` and `b` query parameters |
| `/baseline11` | POST | Sums the query parameters + the request body |
| `/baseline2` | GET | The same handler under the name the HTTP/2 profiles use. Kept for parity with the other Go entries; fasthttp speaks no HTTP/2, so nothing here drives it |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body verbatim. `8gbit` posts to it over TLS on 8081 |
| `/delay/{ms}` | GET | Answers `ms` after waiting that long |
| `/static/{file}` | GET | Serves `/data/static`, pre-compressed twin where the client takes one |
| `/async-db` | GET | Items in a price range from Postgres (`min`, `max`, `limit`) |
| `/crud/items` | GET, POST | List by category; upsert by id |
| `/crud/items/{id}` | GET, PUT | Read through the cache; update and invalidate |

## Notes

- **No `fiber.Config`.** The app is built with `fiber.New()`, so every setting the App itself
  takes is the framework's own default — the 4 MB body limit included, which is forty times the
  largest body anything sends this entry (100 KB, in the `8gbit` validation). What is not
  default is in `ListenConfig`: `EnablePrefork` (the section below) and `DisableStartupMessage`,
  which only silences a banner.
- One worker process per CPU the container is given, through Fiber's `EnablePrefork`: the
  master binds nothing and every worker accepts on its own `SO_REUSEPORT` socket. The section
  below has the mechanics and what it costs.
- Routing and binding through the Fiber API: `/baseline11` reads its two operands with
  `fiber.Query[int]`, `/json/{count}`, `/delay/{ms}` and `/crud/items/{id}` read their path
  parameter with `fiber.Params[int]`, and `/async-db` and `/crud/items` read theirs with
  `fiber.Query[int]` as well. No request materialises the query string into a map.
- JSON through `c.JSON`, serialized per request.
- The `compress` middleware is mounted on `/json` and `/static` rather than on the whole app.
  What that leaves out is either answered in a handful of bytes — `/pipeline`, `/baseline11`,
  `/delay/{ms}`, `/baseline2`, where fasthttp's 200-byte floor means the middleware could only
  stamp a `Vary` header on the endpoints the throughput and CPU-per-request profiles drive — or
  wanted back unchanged, which is `/echo`. `/async-db` and `/crud/*` are outside it too; their
  profiles send no `Accept-Encoding`, so nothing would have compressed there anyway.
- A worker that is signalled directly finishes the requests it is holding before it exits: a
  request signalled 0.4 s into a 1.5 s handler still answers 200 at 1.5 s. `docker stop` is a
  different path and does not drain — it signals PID 1, which here is the prefork master, and
  when the init of a PID namespace exits the kernel takes the rest of the namespace with it.

## Added profiles

`async`, `json-tls`, `static-tls` and `async-db`. The `/crud/*` routes are still served, but no
profile drives them any more.

- `json-tls`, `static-tls` and `8gbit` share the listener on `8081`, opened when
  `/certs/server.crt` and `/certs/server.key` are both present. It is the same router behind
  TLS, not a second copy of the handlers. The keypair is loaded here and handed over as
  `ListenConfig.TLSConfig` rather than as `CertFile`/`CertKeyFile`: that convenience path
  installs a `TLSHandler` whose `GetCertificate` callback writes the ClientHello onto one
  shared struct on every handshake, which `go build -race` reports as a data race under
  concurrent handshakes — and this port is driven at 512 to 16,384 connections.
- What the static profiles require is that the response follow the disk: replace a file and the
  next response carries the new bytes. Serving from memory is allowed in every mode, but only
  through a cache that is the framework's own — and Fiber's static middleware cannot be that
  cache here, because it holds open file handles and never re-stats them, so a replaced file
  keeps being served for up to `CacheDuration`, and its `Compress` option writes `.fiber.br`
  twins into a directory the harness mounts read-only. So this entry reads per request and
  holds no copy of its own.
- Where the client accepts an encoding, the `.br`/`.gz` twin the harness ships beside the file
  is read instead of the original, picked with Fiber's own `AcceptsEncodings`. The profile
  allows selecting the variant off `Accept-Encoding` where a framework has no API for it, and
  the alternative is not compression but the rotation going out at full size: the 20 files
  weigh 1.21 MB as originals and 318 KB as the twins the client is offered, and the compress
  middleware sits the round out because fasthttp's Accept-Encoding matcher compares whole
  tokens while the profile sends `br;q=1, gzip;q=0.8`.
- `/delay/{ms}` parks the handler's goroutine on a timer, which is what makes `async` a
  question about the process rather than about the handler.
- Postgres goes through `pgx`, and every database and cache call carries a deadline: Fiber's
  `Ctx.Context()` is a background context and fasthttp has no per-request cancellation to put
  in it, so nothing else would bound a query whose client has gone away.
- The crud read is cache-aside on Redis with a 200 ms TTL and an explicit delete on update,
  when `REDIS_URL` is set. The harness passes one only to the compose stacks, so in a
  single-container run this reads straight through to Postgres.
- `tags` is a JSONB column, so it arrives as bytes rather than as a Go slice.

## Prefork

`app.Listen(":8080", fiber.ListenConfig{EnablePrefork: true})` hands off to fasthttp's prefork
manager: one worker process per CPU the container is given.

### Why this is standard and not tuned

- The mode's own rule page allows it twice: "Worker/thread counts matching available CPU cores"
  under **Allowed**, and "Setting worker count to match CPU cores" under deployment-environment
  tuning. Its **Not allowed** list — undocumented flags, experimental options, settings that
  disable buffering or validation — covers none of this. `EnablePrefork` is a documented public
  field, and Fiber's own documentation carries deployment guidance for it (run it inside a
  trusted boundary, prefer container isolation), which is exactly one benchmark container.
- The board already runs this way. `express`, `fastify` and `koa` fork one cluster worker per
  core, `aiohttp` describes itself as "one forked worker per core sharing the port with
  SO_REUSEPORT", and all of them are `mode: standard`. Counted in the sources rather than in
  the prose — a `SO_REUSEPORT` socket, a `prefork` manager or a `cluster.fork` in an entry's
  own code or build files — 34 standard entries run this way, this one included.
- The socket options that come with it are settled here too. `go-fasthttp` — flagship, standard,
  on the same profiles — calls the identical `reuseport.Listen`, and `axum` added one
  `SO_REUSEPORT` listener per core in
  [#1361](https://github.com/MDA2AV/HttpArena/pull/1361) and stayed standard.

The counter-argument, stated because a reviewer will find it: the `baseline` profile's standard
rule reads narrower than the mode page — "No custom TCP tuning, no experimental flags, no worker
count beyond framework defaults." Two pages, one question, opposite answers. It resolves the way
it does here for two reasons. `standard.md` is the mode's own rules page and is explicit twice
over, while the profile string is a one-line summary of it; and the socket options are not this
entry's to begin with — `reuseport.Listen` is what fasthttp's own prefork path calls, so what a
reviewer would be pricing is a framework default rather than something this entry set — the
distinction `standard.md` draws in its static-file section, "what the framework gives you, not
what can be written against it", applied to sockets instead of caches. Taking the narrow reading
instead does not reclassify this entry alone: it reclassifies the other 33, `go-fasthttp` and
`axum` among them.

`short-lived` is sometimes cited here too and does not belong in the argument: its standard rule
is about keep-alive and connection pooling ("Must use the framework default connection handling.
No custom keep-alive tuning or connection pooling optimizations"), and what its tuned side lists
as permitted for tuned entries says nothing about what standard ones may do.

- The master binds nothing. It re-executes the binary `GOMAXPROCS` times with
  `FASTHTTP_PREFORK_CHILD=1` set, then supervises: a worker that dies is replaced, until the
  cumulative number of exits passes `PreforkRecoverThreshold` (Fiber defaults it to
  `max(1, GOMAXPROCS/2)`), at which point the master gives up and the container exits with it.
- On the benchmark cpuset (`0-31,64-95` — 32 physical cores, 64 hardware threads) that is 64
  workers, each dropped to `GOMAXPROCS(1)` by prefork itself: one Go runtime per hardware
  thread rather than one runtime scheduling all of them.
- Each worker binds its own socket through `reuseport.Listen` and the kernel spreads accepted
  connections across them. That listener also carries `TCP_DEFER_ACCEPT` and `TCP_FASTOPEN`,
  which are fasthttp's defaults for a reuseport socket rather than anything this entry sets.
- The TLS listener on `8081` is opened the same way, once per worker: in a child
  `EnablePrefork` means "take the `SO_REUSEPORT` socket for this address", not "fork again".
  Without it every worker would race for an ordinary bind and all but one would lose it.
- The dataset, the Postgres pool and the Redis client are loaded only where `fiber.IsChild()`
  is true. The master has no use for them, and a pool opened before the fork would hand the
  same connections to every worker.
- Anything the container holds once is divided by the worker count. The Postgres pool is the
  one that matters: `DATABASE_MAX_CONN` is a budget for the container, not for a process.

What it costs is one Go runtime per hardware thread — N heaps, N garbage collectors, N sets of
background threads — paid for whether or not requests are arriving. The memory figure carries
that directly. Whether it also lands on `latency-1m` and `latency-10k`, which price CPU per
request at a fixed rate, is what those profiles are for: it depends on whether the workers get a
core each, and here they do — the harness pins the server to `0-31,64-95` and the load generator
to the other half of the chip. `/benchmark -f fiber` reports the deltas against this entry's
results on `main`, so the trade is a number rather than an argument.

## Tuned sibling

Four things this entry leaves at the framework's defaults — sonic behind `c.JSON`, the compress
middleware at its best-speed level, the Postgres pool filled at startup, and fasthttp at `master`
for the go-brrr brotli it swapped in — are set in the [`fiber-tuned`](../fiber-tuned/) entry,
`mode: tuned`. sonic is the one standard mode forbids.
The compress level is an option of the same middleware, and `carter` and `salvo` run theirs at
level 1 in standard mode; it stays at default here so that "default configuration" stays true,
and its README has the numbers: on a sandbox core, json-comp costs this entry roughly 380 µs per
request, about 260 of them brotli at fasthttp's default level 4. The board runs both entries, so
each setting is a delta against this one rather than a claim.
