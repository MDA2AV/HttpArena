# libuvcpp

libuvcpp on the libuv event loop, one loop per available core.

## Stack

- **Language:** C++11
- **Library:** libuvcpp 1.6.x ([repo](https://github.com/Antruly/libuvcpp)),
  built from source in the image
- **Build:** `cmake -DCMAKE_BUILD_TYPE=Release` on `ubuntu:24.04`, with libuv,
  llhttp, zlib, nghttp2, ngtcp2, nghttp3 and OpenSSL 3.5 all built statically
  into `libuvcpp.so`; the entry is `g++ -std=c++11 -O2 -DNDEBUG`

The library is built from source rather than installed from the published
`libuvcpp-1.6.x-linux-x64` release package, because that package is built with
both database backends off — the release workflow asserts it with an `ldd` check
that fails if `libpq.so` appears — and `/async-db` needs the Postgres backend.
Everything else about the build follows that same release recipe. The pinned
revision installs `include/zlib.h` and `include/zconf.h` along with the library,
which matters because `web/uvcpp_ws_parser.h` includes `<zlib.h>` whenever
`UVCPP_ZLIB_ENABLE` is 1 — and `uvcpp_config.h` sets that unconditionally, so a
consumer cannot opt out of it. At the older `v1.6.1` pin the install rules had
no such entry and the image carried `zlib1g-dev` to compensate; the headers are
now part of what `cmake --install` writes, so that package is gone. OpenSSL is
built from source as well: its QUIC API (`SSL_set_quic_tls_cbs`) is what the
HTTP/3 listener needs, and Ubuntu 24.04's own OpenSSL is too old to have it.

## Listeners

One process opens five listeners:

| Port | Protocol | Serves |
|------|----------|--------|
| 8080 | HTTP/1.1 + prior-knowledge `h2c` | `baseline`, `limited-conn`, `pipelined`, `async`, `async-db`, `json-comp`, `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited`, `latency-*`, `unary-grpc` |
| 8081 | TLS, ALPN `http/1.1` | `json-tls`, `8gbit`, `static-tls` |
| 8082 | cleartext `h2c` | `baseline-h2c`, `json-h2c` |
| 8443/tcp | TLS, ALPN `h2` | `baseline-h2`, `static-h2`, `unary-grpc-tls` |
| 8443/udp | QUIC, ALPN `h3` | `baseline-h3`, `static-h3` |

The four TCP legs are `uvcpp_web_app` instances — the library's documented
high-level server, and where routing, path and query parameters, static files
and WebSocket come from. HTTP/2 is on by default once `enable_ssl` is called, so
8443 uses the framework's own ALPN list; 8081 pins `set_http2_enabled(false)` so
it cannot answer h2.

8080 carries two protocols because `unary-grpc` names that port (`http://
localhost:8080`) while the h1 profiles need it too. The two are told apart by
the first 24 bytes of each connection: the RFC 9113 preface is byte-exact, so a
connection that starts with it is h2c for the rest of its life and anything
else is HTTP/1.1. That settles once per connection, and it is a decision rather
than a guess. `baseline-h2c` and `json-h2c` do not need the split — they have
the platform's dedicated h2c port (8082) to themselves.

The QUIC leg is the low-level `uvcpp_http_server`, because `uvcpp_web_app` has
no QUIC API at all. It serves `/baseline2` as a route and the static tree
through `uvcpp_static_server` mounted as the fallback handler;
`uvcpp_http_server` has no `serve_static()` of its own, and on h3 a deferred
reply is sent through the request's reply handle rather than a client pointer,
so the fallback works without one.

8080 also carries the compose hop. In the three compose profiles (`gateway-64`,
`gateway-h3`, `production-stack`) it is the backend — the server runs with no
certificates mounted, so its two cleartext listeners are the only ones it opens,
and the edge proxy owns 8443. Those two are moved to **8085/8086** in the
compose files (`H1_PORT` / `H2C_PORT` in the `server` service's environment,
read by `env_port()` in `main.cc`), because both stacks run on the host
network and the entry's own ports are not necessarily free there: the harness
starts an instance of this same image as a plain container for the isolated
profiles and leaves it up for the whole run, gateway phases included, and the
`server` service exits 1 if a bind fails. Moving the backend rather than
detecting the collision keeps the failure loud — an occupied port is still an
error, it is just no longer a port this deployment claims. Unset, the entry
binds 8080/8082 exactly as before.

A compose stack opens one more listener on **8080** (`H1_PROBE_PORT`, set to
8080 alongside the other two). It is not part of the hop; it is where the
benchmark's readiness probe looks. `framework_wait_ready()` has no gateway case
(`scripts/lib/framework.sh`), so a gateway profile falls through to
`http://localhost:8080/baseline11?a=1&b=1`, and a profile whose probe fails is
skipped with a warning and publishes no numbers at all — which is what a
backend that had moved to 8085 does silently. So the stack answers there as
well, best-effort: in a *validation* run it loses that bind to the harness's own
instance, which holds 8080 for the whole run by design, logs one line about it
and carries on serving the edge on 8085. It is one worker loop, it answers
`/baseline11` with the same handler the 8080 leg registers, and nothing in any
profile measures it.

The 8443 h2 listener answers `/json/{count}`, `/async-db`, `/public/baseline`
and `/public/json/{count}` as well as its own two routes. The reason is
`localhost`: the edge binds `[::1]:8443` and this process binds `0.0.0.0:8443`,
so a client that resolves `localhost` takes the edge when the edge is already
listening and this listener while a freshly built edge image is still starting.
That window is where a validation run's first checks land, and an endpoint
missing here reads as a 404 that the deployment is supposed to serve. `/api/*`
is deliberately absent — those routes need the edge's verified `X-User-Id`, and
the profile forbids the framework from doing the JWT verification itself.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Same, on 8443 over h2 and h3, and on the backend's cleartext port for the gateway hop |
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/delay/{ms}` | GET | Answers after `ms`, with the parameter echoed verbatim |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m`; also on 8443 over h2 |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/*` | GET | Files from the mounted `/data/static` |
| `/ws` | WS | Echoes text and binary frames back on the same opcode |
| `/benchmark.BenchmarkService/GetSum` | POST | gRPC unary, on 8080 over h2c and on 8443 over h2+TLS |
| `/async-db` | GET | Postgres range query, `min`/`max`/`limit`; also on 8443 over h2 |
| `/public/baseline` | GET | The `a + b` query sum, anonymous side of the edge |
| `/public/json/{count}` | GET | Same serializer as `/json/{count}` |
| `/api/items/{id}` | GET | Cache-aside read, `X-Cache: MISS`/`HIT`, needs `X-User-Id` |
| `/api/items/{id}` | POST | `UPDATE` then cache invalidation, `204`, needs `X-User-Id` |
| `/api/me` | GET | The authenticated user, cache-aside at 30 s, needs `X-User-Id` |

## Notes

- **Routing, params, static and WebSocket are the framework's.** Handlers are
  registered with `app.get` / `app.post` / `app.websocket`, path parameters use
  `:name`, and static files go through `serve_static`, which is libuvcpp's
  documented static handler. Nothing in the entry reads or caches static bytes
  itself — the handler revalidates each request against the file's size and
  `mtime` (seconds and nanoseconds), so a replaced file is served immediately.
- **JSON is serialized per request through the framework's own writer.** The body
  is built by walking the live dataset with `uvcpp_json_writer` — libuvcpp's
  documented streaming constructor, the one `doc/json-guide.md` describes — and
  the `total` field is computed inside the loop, from the values the writer is
  reading. Nothing is pre-serialized, cached, or spliced out of a previously
  rendered buffer, and the response is byte-for-byte what the previous
  implementation produced. What moved is what writing it costs: a key now goes
  out in one `append` instead of four or five, which on this box takes
  `/json/50?m=6` from 80.4 to 63.2 us of server CPU per request — a repeat run
  put the same pair at 73.8 and 59.2 us — measured best-of-3 interleaved rounds
  with the server pinned to 6 single-threaded cores and saturated at 100% of
  them. With `Accept-Encoding: gzip, br` the pair is 155.0 to
  141.1 us: compressing the 8.4 KB body costs more than serializing it, so the
  gain is smaller there, not absent. End to end (h2load, best of 3): 73.7k ->
  94.2k req/s over h2c and 81.0k -> 96.3k over h1. Against the copy-then-dump
  shape this handler used before — each item duplicated into a second DOM and
  the whole payload dumped, still in `main.cc` as `build_json_general`, the
  fallback for any value the writer cannot reproduce byte-for-byte — the whole
  path costs 3.0x less CPU per request (176.0 -> 59.2 us).
  The dataset is now read out of the DOM once at startup into a flat array
  (`flat_item` plus a single character pool, ~5 KB for all 50 items), so the
  handler walks that instead of 50 `std::map` trees; the walk it replaces cost
  about 140 ns per item. That takes the serialization step for `/json/50?m=6`
  from 31.0 to 23.4 us (9 interleaved rounds in one process, median of the
  per-round ratios 0.751 / 0.769 / 0.793 over three repeats) and 10.8-11.7% of
  server CPU per request end to end (11 paired rounds: 0.883 and 0.893 in two
  runs). Nothing is pre-rendered — every request still walks the live items and
  writes their bytes. The flattening is not trusted on faith:
  `build_flat_dataset` writes each item both ways and enables the fast path only
  if every one matches the reference byte for byte at three multipliers, so a
  dataset of any other shape stays on the reference path and says which path it
  is on at startup. Parsing is now the framework's `uvcpp_json_parse` rather
  than nlohmann's `parse` directly, so every JSON call the entry makes is one
  the library publishes.
- **Compression is the framework's built-in response compression** (gzip), which
  answers `Accept-Encoding` per request and adds no `Content-Encoding` when the
  client sends none. The library has no brotli compressor, so an `Accept-Encoding:
  br, gzip` request is answered with gzip for anything the handler compresses
  live.
- **Where the dataset ships a pre-compressed twin, the handler serves it**
  (`precompressed`, on for every static leg). 15 of the dataset's 20 assets carry
  a `.br` and a `.gz` beside them, and the static profiles send
  `Accept-Encoding: br;q=1, gzip;q=0.8`, so those 15 go out as the shipped
  brotli file with `Content-Encoding: br` and `Vary: Accept-Encoding`. This is
  the same thing every other entry does — nginx `gzip_static`, Caddy
  `precompressed br gzip` (which this entry's own edge Caddyfiles already use),
  actix `try_compressed()` — and the entry neither produces nor caches those
  files: it is the framework's option, pointed at the dataset as mounted. A
  request for a file with no twin, or one that sends no `Accept-Encoding`, or a
  `Range` request, gets the live path unchanged.
- **The libuv thread pool is sized at the top of `main()`.** Two things ride
  that one pool: the static handler's file I/O, and every `/async-db` query. The
  size is the wider of "one thread per available core" (libuv's default is 4
  regardless of the machine; `latency-500k-8cpu` pins the container to 8 CPUS,
  and libuv's `uv_available_parallelism()` is cpuset-aware) and
  `DATABASE_MAX_CONN`, because a libpq call blocks in `recv` — what caps
  in-flight queries is slots, not cores. libuv spawns pool threads on demand, so
  the wider figure costs nothing while the pool is idle.
- **The `/delay/{ms}` reply is a timer on the connection's own loop**, not a
  blocking sleep, so other connections are served while it waits.
- **`/echo` answers `application/octet-stream`**, which is outside the
  framework's compression set, so the bytes come back unchanged.

### `/async-db`

- **The pool is the library's `uvcpp_db_pool`**, one per process, opened at
  startup from `DATABASE_URL` and sized from `DATABASE_MAX_CONN` (1..max, max
  from the variable, defaulting to 256). Not one pool per worker loop: the pool
  is the thing that owns the connections, and it is written to be called from
  any thread.
- **The query is asynchronous**, through `pool.query(loop, sql, params, cb)`.
  That call borrows a connection, runs the statement and returns the connection
  — all on a libuv thread-pool thread — and then invokes the callback on the
  connection's own loop thread. The handler returns before libpq is touched; the
  reply is written from the callback, which holds a copy of `next` to keep the
  response alive. Nothing on the event loop ever blocks on the database.
- **`$1/$2/$3`, not `?`.** libuvcpp's driver does not translate placeholders
  between dialects, on purpose — `?` is a legal operator in Postgres for jsonb
  and hstore, so a translation layer could not tell the two apart. This is the
  entry's only Postgres-specific line.
- **`tags` is re-parsed.** Postgres returns JSONB as text (OID 3802 is not one
  of the driver's mapped types, and an unmapped OID degrades to the string libpq
  returned), and that string *is* the JSON array — so it is parsed back into an
  array rather than spliced in as a quoted string.
- **Failure is not fatal and not silent-in-the-wrong-way.** With no
  `DATABASE_URL`, or a pool that will not open, `/async-db` answers the
  documented `{"items":[],"count":0}` and the other profiles serve normally.
- **At the profile's own generator shape the pool saturates without failing.**
  `scripts/lib/tools/gcannon.sh` drives this endpoint with `-r 25`, so each
  socket serves 25 requests and is then retired and replaced; 1024 is how many
  are live at once, not how many exist. Measured in that shape, against a
  Postgres seeded with the profile's own 100,000 rows, with
  `DATABASE_MAX_CONN=256` and the server's `max_connections` the same figure:
  84,807 requests over 10 s across 3,072 socket retirements, **zero** empty
  bodies and zero with the wrong `count`. That combination is the tight one,
  because the pool's ceiling and the server's are the same number — the pool
  filled it and later requests waited for a free connection instead of being
  rejected. A pool sized *above* `DATABASE_MAX_CONN` would answer `count: 0`
  under exactly this load, which is the failure the profile's standard rule
  names.

### The h3 leg

Three things about 8443/udp are worth stating, because they are deliberate:

- **The handler splits the query string by hand.** The low-level
  `uvcpp_http_request` exposes only `url`, with no path or query accessor, so
  `?a=13&b=42` is parsed in the handler. The arithmetic is the same function the
  h2 leg calls, so the two cannot disagree. This is the entry's only hand-rolled
  parsing, and it exists because the high-level app has no QUIC support.
- **`/static` is served by `uvcpp_static_server`, mounted as the fallback
  handler** rather than through a route, because `uvcpp_http_server` has no
  `serve_static()` of its own. That handler marks its responses *deferred* — it
  answers from the libuv thread pool once the file has been read — so the h3
  dispatch path has to accept a deferred reply instead of rejecting it with a
  500. It does: the h3 handler is handed a reply handle it can send through
  after it returns, which is what `send_h3_response` was already able to do per
  stream. `set_spa_fallback(false)` matches the h1/h2 legs, so a miss is a 404
  on all of them rather than `index.html` with a 200 here.
- **The static tree is `uvcpp_static_server`, not `uvcpp_web_static`.** The
  web-layer static server is reachable only through `uvcpp_web_app`, which has
  no QUIC API at all, so the h3 leg cannot use it. Both revalidate against the
  file's size and `mtime` per request, so a replaced file is served immediately
  on either. Both also take `precompressed`, from the same shared rule (the two
  servers call one `http_pick_precompressed_variants()`), so the twin a request
  gets does not depend on which leg answers it. Turning it on matters far more
  here than on the `uvcpp_web_app` legs: `uvcpp_static_server` has no
  compressed-variant cache, so without it the handler runs zlib over the whole
  file on the loop thread once per request.

### The compose stacks

`gateway-64`, `gateway-h3` and `production-stack` are orchestrated by
`compose.<profile>.yml`, all of which run `network_mode: host` and put a stock
unmodified `caddy:2-alpine` at the edge. There is no hand-written proxy in this
entry: the gateway profiles' rules exclude one ("No custom proxy
implementations"), and a Caddyfile that says `file_server` and `reverse_proxy`
is the whole of it.

| Profile | Compose file | Services |
|---|---|---|
| `gateway-64` | `compose.gateway.yml` | proxy + server |
| `gateway-h3` | `compose.gateway-h3.yml` | proxy + server |
| `production-stack` | `compose.production-stack.yml` | edge + cache + authsvc + server |

- **The edge serves `/static/*` off the mounted disk itself**, with
  `file_server { precompressed br gzip }` — never forwarded to the backend. That
  is what the gateway rules require and what the profile measures: a front door
  doing TLS, compression and file I/O in front of an application server that
  answers only the dynamic endpoints.
- **The backend hop is plain HTTP/1.1 over loopback**, not h2 and not a Unix
  socket. Many independent h2 streams arriving from the client fan out across
  the server's per-core loops through a pool of h1 keepalive connections; a
  single h2 connection to the backend would re-serialize them behind one
  connection's flow control.
- **The same Caddyfile covers gateway-64 and gateway-h3.** `protocols h1 h2 h3`
  binds 8443 on tcp and udp from one server block; only the load generator
  differs (`h2load --alpn-list=h3`).
- **The server is not given `/certs`.** `main.cc` opens its 8081 and 8443
  listeners only when the certificate pair is readable, so with none mounted it
  comes up on its two cleartext ports and leaves every TLS port to the edge.
  Mount the certificates into both services and the two race for 8443.
- **The backend's ports are 8085/8086, not 8080/8082.** Both ends of the hop are
  set together — `H1_PORT`/`H2C_PORT` in the compose `server`'s environment and
  the upstream in the Caddyfile. The stack runs on the host network, and 8080
  and 8082 are exactly the two ports something else can already be holding
  there, so the backend is given ports of its own rather than racing for the
  entry's defaults. 8080 is still opened, but as the readiness probe's landing
  pad (`H1_PROBE_PORT`) rather than as the hop: the benchmark and the validation
  run disagree about who owns that port, and the probe only needs something to
  answer on it. Neither costs the measured path anything — the extra listener is
  one idle loop.
- **`production-stack`'s JWT verification is the shared sidecar, unmodified** —
  `frameworks/_shared/authsvc/`, built from the same directory every entry uses.
  The edge fires `forward_auth` at it for every `/api/*` request and copies back
  the `X-User-Id` it resolves; the token cost is not cached, because that cost is
  part of what the profile measures. The server never parses a token, never reads
  `Authorization`, and separately returns 401 for any `/api/*` request that
  arrives with no `X-User-Id` at all.
- **Cache-aside is in-process.** The profile's implementation guide lists
  "in-process only: no Redis for caching, just a local hashmap with TTL" beside
  the L1+L2 and Redis-only options, and this entry takes it: the profile runs one
  server process, so a shared L2 would add a network hop and a serialization step
  to reads already held in memory. Item entries live one second and user entries
  thirty, both the profile's own ceilings, and a `POST /api/items/{id}` drops the
  key before answering `204`. The `cache` service the profile requires is still
  in the compose file and the server still waits for it to report healthy — that
  is the rule, and it is also what makes a cache that cannot bind fail the stack
  instead of leaving the run measured against something else.
- **The invalidated key is dropped unconditionally**, whether or not the `UPDATE`
  reported a row, so a write to an id the reads have cached cannot leave a stale
  copy behind.

### Not subscribed

`fortunes`, and the remaining unrelated profiles. `fortunes` needs an HTML
template engine, which libuvcpp does not have; rendering the table by hand in
the entry would be exactly the "template engine written for the benchmark" the
standard-mode rules exclude.
