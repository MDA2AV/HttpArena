# paozhu

C++20 web framework entry built from the upstream [paozhu](https://github.com/hggq/paozhu) clean scaffold. The image fetches the pinned upstream tree — or uses a source archive shipped in the build context — runs its `mini_project.sh` to strip the ORM / view / demo layers, then compiles the framework core together with the benchmark controllers in `src/controller/src/` (`arena.cpp` for the CPU/static routes, `db.cpp` for the Postgres ones).

## Stack

- **Language:** C++20
- **Engine:** paozhu (standalone Asio event loop, native HTTP/2)
- **Build:** `debian:bookworm` → `debian:bookworm-slim`, GCC with `-O3 -march=native`, `-DENABLE_BENCHMARK=ON`
- **Source:** upstream commit pinned by the `PAOZHU_REF` build arg — currently `d73100bd` (`Add BENCHMARK send to http2`), which is what the Dockerfile builds. The results quoted in *Validation status* were produced on `71305087` (`v1.17.4-16`), and the two revisions do not behave identically (raw POST bodies, HTTP/2 send loop), so re-run `validate.sh` on `d73100bd` before attributing any number to the current pin. Local development tree is `/Users/hzq/paozhu`. When `vendor/paozhu-src.tar.gz` is present the Dockerfile unpacks that archive instead and `PAOZHU_REF` is ignored.

## Pinned `CMakeLists.txt`

paozhu is not a linkable library: the app *is* a paozhu project, and its build definition has to reproduce the whole upstream graph (globbing `vendor/`, `libs/`, `common/`, `controller/`, running `paozhu_pre` to generate the router table and linking OpenSSL/zlib/brotli). `src/CMakeLists.txt` is a checked-in snapshot of that file at `71305087`, so the Dockerfile no longer patches upstream text at build time. The snapshot predates the current `d73100bd` pin and has not been regenerated for it; confirming it still matches upstream is part of the pending re-validation. It has exactly two local changes:

1. `option(ENABLE_BENCHMARK "Enable benchmarks" ON)` — benchmark tier is the default for any `cmake` invocation, not just one with `-D`. In upstream code `BENCHMARK` turns off exactly five things: the per-request access log (string build + mutex + list append), the 1000-requests-per-connection keepalive cap, the HTTP/2 concurrent-stream GOAWAY above 512, the 10 µs pacing floor in the HTTP/2 send loop, and the 5 s `httpwatch` maintenance loop (temp-file sweep, certificate and timed-task work) which collapses into a plain sleep. Two other guards are inert under this entry's conf: the rate-limiter removal (`rate_limit_status = 0` already) and the dotted-URL disk pre-check (it only runs when `usehtmlcache` is set, and both conf files leave the key out — see *Notes*).
2. Both branches of the `add_executable` generator expression point at `startup/main_docker.cpp` — the upstream Release default `main_daemon.cpp` forks and would make PID 1 exit immediately.

`Dockerfile` copies this file over the unpacked upstream tree after `mini_project.sh`. When bumping `PAOZHU_REF`, refresh the snapshot and re-apply those two changes; the pinned upstream source still supplies everything else the file globs.

`src/mini_project.sh` is pinned for the same reason. Upstream `71305087` aborts its Step 2 under `set -euo pipefail`: `left=$(grep -c ...)` returns 1 once no RBAC markers remain in the stripped `startup/main_dev.cpp`, so the ORM/view layers are never cleared. The checked-in copy adds `|| true` to that single assignment (verified end-to-end); refresh it together with the CMakeLists snapshot when bumping `PAOZHU_REF`.

`src/startup/main_docker.cpp` is pinned too (byte-identical to upstream apart from a header comment): it resolves `argv[1]` to a conf file and installs the SIGTERM handler that the two-conf-dir layout relies on. `mini_project.sh` leaves `startup/` alone, so the file is simply copied over the unpacked tree.

`paozhu_pre` regenerates `common/autocontrolmethod.hpp` and `controller/include/arena.h` from the `//@urlpath` annotations on every build; those generated files are deliberately not checked in.

## Listeners

paozhu opens exactly one plaintext and one TLS port per process, while HttpArena needs four listeners. `src/entrypoint.sh` therefore runs two instances of the same binary, each with its own conf directory:

| Port | Protocols | Instance | Profiles |
|------|-----------|----------|----------|
| 8080 | HTTP/1.1 | `conf/main/server.conf` | baseline, pipelined, limited-conn |
| 8081 | HTTP/1.1 + TLS (ALPN `http/1.1` only) | `conf/h1/server.conf` | json-tls |
| 8082 | h2c (prior-knowledge, cleartext) | `conf/h1/server.conf` | json-h2c |
| 8443 | h2 + TLS (ALPN `h2`) | `conf/main/server.conf` | baseline-h2, static-h2 |

The second instance keeps `http2_enable = 0`, so its ALPN callback never selects `h2` — the json-tls profile requires HTTP/1.1. That switch only governs TLS negotiation: cleartext h2c is detected from the `PRI * HTTP/2.0` connection preface by `checkhttp2()` and works with `http2_enable = 0`, which is why the same instance can serve both :8081 and :8082.

**Why separate conf directories:** `httpserver::run(argv[1])` calls `serverconfig::init_path()` first, which picks `<cwd>/conf/server.conf` when present and only falls back to `argv[1]` when that file is missing. Two conf files in one directory would make both processes load the first one and bind the same ports (SO_REUSEPORT hides the mistake). The image deliberately has no `/app/conf/server.conf`. `serverconfig` also resolves TLS file names relative to each conf file's own directory, so `entrypoint.sh` stages `/certs/server.crt` and `/certs/server.key` into both `conf/main/` and `conf/h1/`.

`/certs` is mounted by `validate.sh` / `benchmark.sh`; missing certificates leave the plaintext listener working and only affect the TLS listeners.

## Endpoints

Registered through paozhu annotations; path parameters must be the final segment.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET / POST | Sums query parameter values, plus the decimal POST body |
| `/baseline2` | GET | Sums query parameter values |
| `/json/{count}?m={multiplier}` | GET | Serializes the first `count` dataset items with `total = price × quantity × m` |
| `/static/{filename}` | GET | Reads `/data/static/{filename}` from disk and serves it with a MIME type |
| `/async-db?min=&max=&limit=` | GET | Async Postgres range query over `items`, returns `{"items":[...],"count":N}` |
| `/fortunes` | GET | Reads the 200 `fortune` rows, appends a runtime row, sorts and renders an HTML table |

`/data/dataset.json` is parsed once at startup into typed fields. String fields are kept as the raw bytes between the source quotes, so escapes round-trip exactly; the response body is serialized per request because `m` varies. A missing or malformed dataset makes `/json` return 400 rather than taking the other profiles down.

Static files are read on every request (no preloaded copy), so a replaced file in the mounted directory shows up immediately. File names are restricted to `[A-Za-z0-9._-]` and must not contain `..`.

## Notes

- `src/conf/openssl.cnf` is exported as `OPENSSL_CONF`: it keeps TLS 1.3 available while refusing TLS < 1.2 and the weak cipher families probed by the TLS checks. It does not change the certificate.
- `src/conf/orm.conf` is a template copied to `/app/conf/orm.conf.tpl`; `entrypoint.sh` renders it into `/app/conf/main/orm.conf` only when the harness injects `DATABASE_URL` / `DATABASE_MAX_CONN`. Without a DB profile there is no `orm.conf` beside either `server.conf`: `startup_orm_init()` calls `init_orm_conn_pool()` unconditionally, and `get_orm_config_file()` returns an empty list when the file is absent, so no pool is created. `serverconfig` resolves `orm.conf` relative to each conf file's own directory, which is why only the main instance (the one serving :8080) gets one. Both `[pg]` groups must carry full connection settings: `type = main` fills `conf_data[0]` (edit pool), `type = second` fills `conf_data[1]`, which `async_get_pg_select_conn()` actually uses for SELECTs.
- `/async-db` and `/fortunes` use `orm::db_conn("pg")` with `co_await async_query()` plus small `set_val` row types instead of a generated ORM model — `mini_project.sh` empties `orm/` and `models/`. paozhu's own Asio Postgres driver (SCRAM-SHA-256) is compiled into the binary, so no `libpq` is needed. Both handlers share an async gate that caps in-flight queries at the smaller of the `DATABASE_MAX_CONN` budget and the pool's smallest per-slot quota: the framework splits `maxpool` across io_context slots, and staying under one slot's quota keeps even a fully skewed request distribution out of the pool's wait-timeout path.
- `/fortunes` renders the HTML per request in the handler: `mini_project.sh` also empties `view/` and `viewsrc/`, so `peer->view()` has no template to load. The runtime row, byte-ordinal sort and HTML escaping live in `src/controller/src/db.cpp`.
- Every `//@urlpath` handler in `arena.cpp` and `db.cpp` uses the coroutine form (`asio::awaitable<std::string>` + `co_return ""`), so `paozhu_pre` registers them all through `co_reg`. Only the DB routes really suspend (`co_await async_query()`); the CPU/static handlers have no `co_await` but share the same handler shape.
- Raw (non-form, non-JSON) POST bodies are spilled to a temp file only when they exceed `CONST_HTTP_RAW_POST_SIZE` (2 MB). At the current `d73100bd` pin a 2-byte `POST /baseline11` body therefore stays in `httppeer::rawcontent`, and `raw_body()` returns it without touching the disk; the temp-file branch only exists for oversized bodies. At `71305087` every raw POST body went to a file and `raw_body()` had to read and unlink it — which is why that branch is still there and why the earlier measurements include per-POST file I/O that the current pin does not.
- Only the `[default]` site section is configured, so every `Host` / SNI falls back to site 0.
- `usehtmlcache` is intentionally absent from both conf files; a present key enables the disk pre-check for dotted URLs. Because the key is absent the pre-check never runs, so it never competes with `/static/:filename` either way, and `BENCHMARK` compiling that pre-check out is a no-op for this entry.
- Static compression is not implemented: `arena_static` ignores `Accept-Encoding` and always returns the identity bytes. The rules make compression optional for `static-h2` and only measure it when the response carries a `Content-Encoding`, so nothing fails today. Two facts for a later decision: `data/static` already ships `.br` and `.gz` twins next to every compressible original (`*.webp` and `*.woff2` have none), and the `static-h2` h2load run does send `Accept-Encoding: br;q=1, gzip;q=0.8`. Serving those twins by content negotiation is allowed by the static rules and is the largest per-request byte reduction available (about 1.24 MB of identity bodies per 20-file cycle); it is left out on purpose because it changes the bytes-per-request profile.
- The two processes use separate `temppath` / `logpath` directories so they never race on scratch files.
- `cothreadnum` in both conf files is a floor, not the worker count: upstream computes `max(cothreadnum, hardware_concurrency() + 4)`. Under the profile cpuset (`0-31,64-95`, 64 CPUs) each process runs about 68 io threads, not 8, and the second process contributes a second set that stays idle while the other port is being profiled.
- `PAOZHU_REF` selects the upstream revision. The Dockerfile uses a direct `codeload.github.com` tarball URL: `github.com/.../archive/...` 302-redirects to codeload and that hop is blocked on some networks.
- On slow or offline networks, ship a source archive in the build context instead of downloading it: `git -C /Users/hzq/paozhu archive --format=tar.gz --prefix=paozhu-<sha>/ -o frameworks/paozhu/vendor/paozhu-src.tar.gz HEAD`. The Dockerfile prefers `vendor/paozhu-src.tar.gz` when present. The archive is ~36 MB and is deliberately not checked in.
- `APT_MIRROR` is an optional build arg for networks where `deb.debian.org` is slow, e.g. `--build-arg APT_MIRROR=mirrors.aliyun.com`; empty keeps the distro default.
- Local development: `docker build -t httparena-paozhu frameworks/paozhu && VALIDATE_SKIP_BUILD=1 ./scripts/validate.sh paozhu`. Without `VALIDATE_SKIP_BUILD=1`, `validate.sh` rebuilds with `--no-cache` and repeats the full C++ compile. `PAOZHU_REF` can be overridden with `--build-arg PAOZHU_REF=<sha-or-branch>`.
- **Validation status:** the `62 passed, 0 failed` figure was measured on a 4-core / 16 GB Ubuntu 26.04 host with `PAOZHU_REF=71305087` ("Fix http1 http2 multipart part", `v1.17.4-16`), with TLS verdict **pass** and all three chunked POST checks passing (`POST /baseline11` with a chunked body and both fragmented chunked-pipeline cases), alongside `async-db`, `fortunes` and `json-h2c` (all 11 of their checks pass; the DB profiles use a `postgres:18` sidecar). That revision ships Asio 1.39.0 and fixes multipart part-header parsing; it decodes `Transfer-Encoding: chunked` into `peer->files["rawcontent"]["tempfile"]`, which is what `raw_body()` in `arena.cpp` reads, and `40098` is only returned for HTTP/1.0 or malformed transfer encodings. The three pinned files needed no content refresh between `25104601` and `71305087` (only their version comments changed).
- **Pending re-validation:** the Dockerfile now pins `d73100bd`, which is *not* the revision the 62/0 run was made on, so that figure is unverified for the current pin. Both paths those checks exercise changed in between: raw POST bodies up to 2 MB stay in memory instead of going to a temp file, and the HTTP/2 send loop lost its pacing floor. No validation result exists for `d73100bd` yet — run `validate.sh paozhu` before quoting one.

## Mode declaration

`meta.json`'s `"mode"` is a display label only: `rebuild_site_data.py` copies it into the site data, and neither `validate.sh` nor the scoring pipeline reads it. It stays `"standard"`; changing it would not move any measured number.
