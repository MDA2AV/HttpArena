# libuvcpp

libuvcpp on the libuv event loop, one loop per available core.

## Stack

- **Language:** C++11
- **Library:** libuvcpp 1.7.x ([repo](https://github.com/Antruly/libuvcpp)),
  built from source in the image
- **Build:** `cmake -DCMAKE_BUILD_TYPE=Release` on `ubuntu:24.04`, with libuv,
  llhttp, zlib, yyjson 0.13.0, nghttp2, ngtcp2, nghttp3 and OpenSSL 3.5 all
  built statically into `libuvcpp.so`; the entry is `g++ -std=c++11 -O2 -DNDEBUG`

The library is built from source rather than installed from a published
`libuvcpp-<version>-linux-x64` release package. That package was the only
alternative when this entry pinned `v1.6.1`, and at that revision all six of the
release workflow's legs passed `-DUVCPP_ENABLE_DB_MYSQL=OFF
-DUVCPP_ENABLE_DB_PGSQL=OFF` — the workflow asserts it with an `ldd` check that
fails if `libpq.so` appears — while `/async-db` needs the Postgres backend. The
pin has since moved onto development revisions: the `v1.7.0` tag is the nearest
release, the pin is 37 commits past it, and a release package exists only for
a tag, so building the pinned SHA from source is the only way to build exactly
what the pin names. The `1.7.0` packages do carry both remote backends, behind
the runtime-load seam that is why the same `ldd` list still passes, so the
reason is now "the pin is not a release" rather than "the release cannot do it".
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
- **JSON is serialized per request by the framework's JSON backend.** The
  handler walks the live dataset, builds a `uvcpp_json_builder` tree — a public
  and documented API in `doc/json-guide.md` — and writes it out through
  `uvcpp_json_write`, which is yyjson's own serializer. The
  backend is the library's yyjson one; the Dockerfile turns it on with
  `-DUVCPP_ENABLE_YYJSON=ON`, which is the flag all six release legs pass in
  their package builds, so this is the shipped library's configuration and not
  an entry-only one. `total` is computed inside the loop, per request. Nothing
  is pre-serialized, cached, or spliced out of a previously rendered buffer.

  This is deliberate, and it is the one place this entry gives up speed for the
  rules. The profile's JSON tests exist to measure serialization, Standard mode
  asks for "the framework standard JSON serialization"
  (`test-profiles/h1/json-compressed/implementation.md`) and for the
  ecosystem's production-grade library over a hand-rolled alternative
  (`implementation-rules/frameworks/standard.md`: "Experimental or hand-rolled
  alternatives solely for benchmark performance are not permitted"), and the
  same file's exception is what settles which library: "If the framework itself
  bundles or officially recommends a specific library, that library is
  acceptable" — yyjson is bundled by libuvcpp itself and compiled into the same
  `libuvcpp.so` the entry links. `implementation-rules/frameworks/tuned.md`
  lists "Alternative JSON serializers" among the things *Tuned* allows, and
  `uvcpp_json_writer` — the library's streaming writer, a public and documented
  API that `doc/json-guide.md` describes — is such an alternative serializer, so
  this entry does not answer these profiles with it. The same applies to
  `/async-db`, which used to walk the result rows straight into the writer.
  Reading is the same rule the other way: `uvcpp_json_parse` and the
  `uvcpp_json_get_*` accessors rather than nlohmann's `parse` and `value()`
  directly, so every JSON call the entry makes is one the library publishes —
  and none of them can throw out of a libuv callback, which is what those
  accessors exist for.
- **The response bytes did not change.** The handlers used to build an
  `nlohmann::json` DOM and send it through `resp.json()`; both now build a
  builder tree and write it with yyjson. Over 17 URLs — `/json/0` to `/json/50`
  with and without `m`, a `count` past the end of the dataset, a negative
  `count`, an `m` of a million, and five `/async-db` ranges against the seeded
  Postgres — every body is byte-identical between the two, with the same status
  lines and the same `Content-Type`. The order a `std::map` sorted for the DOM
  path is now spelled out in the builder, because insertion order is what a
  builder keeps, and the nested `rating` object is rebuilt key by key for the
  same reason (the data file lists it `score, count`; the response has always
  answered `count, score`).
- **The cost of choosing the backend over the writer, measured.** At the
  1.7.2-dev pin this repository was built on, `/json/50?m=6` through the writer
  cost 63.2 us of server CPU per request against the DOM path's 176.0 us on the
  same 6 pinned cores, and the writer also skipped the per-item DOM copy the DOM
  path makes. Those two figures are the ones this entry reported in earlier
  revisions; they are recorded here as the size of the gap the rules ask it to
  accept, not as a pair it still collects. What it does collect is the backend
  swap itself, same library and only `main.cc` different, arms alternating over
  four rounds at the shape these profiles use (`pipeline = 1`, 1024
  connections): `/json/50?m=6` went from 228.60 to 125.31 us of server CPU per
  request and from 60,350 to 89,605 req/s (the four-round ranges do not overlap:
  228.60-303.57 against 125.31-156.23 us), and `/async-db` at
  `min=1&max=500&limit=20` from 258.62 to 158.95 us and from 30,794 to 41,120
  req/s. Both arms answered zero non-2xx.
- **Compression is the framework's built-in response compression** (gzip), which
  answers `Accept-Encoding` per request and adds no `Content-Encoding` when the
  client sends none, at the library's own default level. The library also
  carries a brotli encoder; the build turns it off (`-DUVCPP_ENABLE_BROTLI=OFF`
  in the Dockerfile). It was on for one run, and that run is why it is off.
  `json-compressed` is the one profile in the suite scored on response bytes
  (`effectiveRps = rps * (minBpr / bpr)^2`), so it is the only place a smaller
  body buys anything, and there the smaller body has to be paid for out of
  requests per second. The two runs' own reported `bpr` put brotli at 1288.4 B
  per response against gzip's 1429.2, so brotli's whole win on that one term is
  `(1429.2 / 1288.4)^2 = 1.23`. Its cost was above that: 5.06x gzip's
  per-request CPU on the board (1238.2 us against the 244.5 us that leg reads
  with gzip, both including the serializer change the other json legs pay too),
  and 1.94x on the same request measured here with the server pinned to 8 cores
  (508.0 us against 257.0 us). So it is a net loss on the only term it can move.
  Turning it off costs nothing else: `Accept-Encoding` is still honoured per
  request, so a client that asks for gzip alone gets gzip; every client these
  profiles use that offers `br` also accepts gzip (`gzip, br` on json-comp,
  `br;q=1, gzip;q=0.8` on the h2 and h3 generators); and the static legs'
  pre-compressed twins are announced the same way whichever encoder the build
  links -- see the next bullet. The profile's own guide asks for what it gets: its
  `standard=` rule wants "the framework or engine's built-in response compression
  (middleware, filter, or equivalent)", its `tuned=` rule only adds "as long as the
  output is valid gzip or brotli", and the worked example under "Expected response"
  answers a request that carried `Accept-Encoding: gzip, br` with
  `Content-Encoding: gzip`. Brotli appears in the page's title, but no rule there
  prefers it, and this entry is `mode: standard`.
- **Where the dataset ships a pre-compressed twin, the handler serves it**
  (`precompressed`, on for every static leg). 15 of the dataset's 20 assets carry
  a `.br` and a `.gz` beside them, and the static profiles send
  `Accept-Encoding: br;q=1, gzip;q=0.8`, so those 15 go out as the shipped
  brotli file with `Content-Encoding: br` and `Vary: Accept-Encoding`. This is
  the same thing every other entry does — nginx `gzip_static`, Caddy
  `precompressed br gzip`, actix `try_compressed()` — and the entry neither
  produces nor caches those files: it is the framework's option, pointed at the
  dataset as mounted. A
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
- **`tags` is parsed, not spliced.** Postgres returns JSONB as text (OID 3802
  is not one of the driver's mapped types, and an unmapped OID degrades to the
  string libpq returned), and that string *is* the JSON array — so it has to
  reach the response as an array rather than as a quoted string. `copy_tags`
  runs `uvcpp_json_parse` over it and copies the array into the builder — an
  array keeps its order in both serializers, so it can be copied whole where an
  object could not — and it is written out with everything else. It used to be
  walked and copied through instead, which was faster and is what the writer
  path did; see the `/json` note above for why that is not this entry's call to
  make.
- **One serializer, one path.** Every response body this profile serves —
  including the ones carrying `tags` — is built with the framework's JSON
  backend and written by the framework's serializer. There is no second,
  hand-written path to prove against the first.
- **Failure is not fatal and not silent-in-the-wrong-way.** With no
  `DATABASE_URL`, or a pool that will not open, `/async-db` answers the
  documented empty result set — `{"count":0,"items":[]}`, built by the same
  serializer and in the same key order as a populated one — and the other
  profiles serve normally.
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
`compose.<profile>.yml`, all of which run `network_mode: host` and put a stock,
unmodified reverse proxy at the edge: `nginx:1.27-alpine` for `gateway-64` and
`production-stack`, `caddy:2-alpine` for `gateway-h3`. There is no hand-written
proxy in this entry: the gateway profiles' rules exclude one ("No custom proxy
implementations"), and a `nginx.conf` or `Caddyfile` that says `file_server` and
`reverse_proxy` is the whole of it.

| Profile | Compose file | Edge | Services |
|---|---|---|---|
| `gateway-64` | `compose.gateway.yml` | `nginx:1.27-alpine` | proxy + server |
| `gateway-h3` | `compose.gateway-h3.yml` | `caddy:2-alpine` | proxy + server |
| `production-stack` | `compose.production-stack.yml` | `nginx:1.27-alpine` | edge + cache + authsvc + server |

- **The edge serves `/static/*` off the mounted disk itself** — Caddy's
  `file_server { precompressed br gzip }`, or for the nginx edges an `alias`
  plus `gzip_static on` — never forwarded to the backend. That
  is what the gateway rules require and what the profile measures: a front door
  doing TLS, compression and file I/O in front of an application server that
  answers only the dynamic endpoints.
- **The backend hop is plain HTTP/1.1 over loopback**, not h2 and not a Unix
  socket. Many independent h2 streams arriving from the client fan out across
  the server's per-core loops through a pool of h1 keepalive connections; a
  single h2 connection to the backend would re-serialize them behind one
  connection's flow control.
- **The gateway and production edges are nginx; only the h3 stack is Caddy.**
  `gateway-64` drives 512 connections × 32 streams = 16,384 concurrent requests,
  and over the profile's HTTP/1.1 upstream hop that multiplexing is what the
  edge costs. Caddy charges roughly 3× nginx per request there — 372–404 µs/req
  for the three entries whose `gateway-64-512` edge is Caddy against 100–110 for
  the three whose edge is nginx — which put the proxy at 96% of its 32 CPUs
  while the server sat at 23% of its own. The same holds on `production-stack`,
  where the edge also runs `auth_request` per `/api/*` call: measured at the
  profile's own 256 reads + 32 writes over a four-core stand-in, Caddy's edge
  cost 440 µs/req at 8.4k req/s and 392 µs/req at 9.5k once its unconfigured
  `forward_auth` upstream was given a connection pool, against 101 µs/req at
  39.2k for nginx in the same shape, with the edge pinned at its core budget in
  all three arms. `proxy/nginx.conf` and `proxy-production/nginx.conf` carry the
  measurements. The profile lists "proxy choice" among the things entries
  compete on, its own example compose uses nginx, and `production-stack`'s
  architecture diagram names nginx and `auth_request` — so both are nginx. The
  h3 profile cannot follow: h3 needs QUIC, and nginx has no HTTP/3 without a
  custom build against a QUIC library, so `gateway-h3` keeps Caddy from
  `proxy-h3/` and lives in its own compose file rather than sharing one
  Caddyfile with `gateway-64` as it used to.
- **`worker_processes` in both nginx configs is a literal, coupled to the
  compose `cpuset`.** nginx's `worker_processes auto` counts the *host's* online
  CPUs, ignoring a container cpuset, and `worker_cpu_affinity auto` is worse: it
  re-pins each worker to a CPU of its own choosing and leaves the cpuset
  entirely. The shipped values are 32 for `proxy/nginx.conf`, matching
  `PROXY_CPUSET`'s default of `0-15,64-79`, and 30 for
  `proxy-production/nginx.conf`, matching `EDGE_CPUSET`'s `0-14,64-78`; change a
  cpuset and its number has to change with it.
- **The nginx edges serve the gzip twin of a static asset, not the brotli
  one.** The framework's own static legs pick brotli, but the gateway and
  production edges are a stock `nginx:1.27-alpine` and brotli needs
  `nginx-mod-http-brotli`, which cannot be loaded into the official image's
  nginx (nginx checks the build signature, so the module has to come from the
  same build as the binary). Serving brotli from a distribution's nginx plus its
  module package was measured on the rig at the gateway profile's concurrency —
  47,275 B of `app.js` against gzip's 54,813, medians of nine runs — and the two
  came out within the rig's own run-to-run spread, so they serve the `.gz`
  sibling like the profile's other nginx edges do. Both encodings are announced
  in `Vary: Accept-Encoding`.
- **The server is not given `/certs`.** `main.cc` opens its 8081 and 8443
  listeners only when the certificate pair is readable, so with none mounted it
  comes up on its two cleartext ports and leaves every TLS port to the edge.
  Mount the certificates into both services and the two race for 8443.
- **The backend's ports are 8085/8086, not 8080/8082.** Both ends of the hop are
  set together — `H1_PORT`/`H2C_PORT` in the compose `server`'s environment and
  the upstream in the edge's config. The stack runs on the host network, and 8080
  and 8082 are exactly the two ports something else can already be holding
  there, so the backend is given ports of its own rather than racing for the
  entry's defaults. 8080 is still opened, but as the readiness probe's landing
  pad (`H1_PROBE_PORT`) rather than as the hop: the benchmark and the validation
  run disagree about who owns that port, and the probe only needs something to
  answer on it. Neither costs the measured path anything — the extra listener is
  one idle loop.
- **`production-stack`'s JWT verification is the shared sidecar, unmodified** —
  `frameworks/_shared/authsvc/`, built from the same directory every entry uses.
  The edge fires an auth subrequest at it for every `/api/*` request (`auth_request`
  for nginx, `forward_auth` for Caddy) and copies back the `X-User-Id` it
  resolves; the token cost is not cached, because that cost is part of what the
  profile measures. The server never parses a token and separately returns 401
  for any `/api/*` request that arrives with no `X-User-Id` at all. The nginx
  edge additionally drops the `Authorization` header before forwarding, so the
  token cannot be re-verified downstream; Caddy's `forward_auth` passes it
  through — checked against a header-dumping backend rather than assumed — which
  is not a violation either, just the looser reading.
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
