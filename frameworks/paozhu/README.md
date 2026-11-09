# paozhu

C++20 web framework entry built from the upstream [paozhu](https://github.com/hggq/paozhu) clean scaffold. The image fetches the pinned upstream tree — or uses a source archive shipped in the build context — runs its `mini_project.sh` to strip the ORM / view / demo layers, then compiles the framework core together with the benchmark controllers in `src/controller/src/` (`arena.cpp` for the CPU/static routes, `db.cpp` for the Postgres ones).

## Stack

- **Language:** C++20
- **Engine:** paozhu (standalone Asio event loop, native HTTP/2)
- **Build:** `debian:bookworm` → `debian:bookworm-slim`, GCC with `-O3 -march=native`, `-DENABLE_BENCHMARK=ON`
- **Source:** upstream commit pinned by the `PAOZHU_REF` build arg (`71305087`, `v1.17.4-16`); local development tree is `/Users/hzq/paozhu`. When `vendor/paozhu-src.tar.gz` is present the Dockerfile unpacks that archive instead and `PAOZHU_REF` is ignored.

## Pinned `CMakeLists.txt`

paozhu is not a linkable library: the app *is* a paozhu project, and its build definition has to reproduce the whole upstream graph (globbing `vendor/`, `libs/`, `common/`, `controller/`, running `paozhu_pre` to generate the router table and linking OpenSSL/zlib/brotli). `src/CMakeLists.txt` is a checked-in snapshot of that file at `71305087`, so the Dockerfile no longer patches upstream text at build time. It has exactly two local changes:

1. `option(ENABLE_BENCHMARK "Enable benchmarks" ON)` — benchmark tier is the default for any `cmake` invocation, not just one with `-D`. `BENCHMARK` drops per-request logging, keepalive/stream caps and the disk pre-check for dotted URLs (which would otherwise shadow `/static/:filename`).
2. Both branches of the `add_executable` generator expression point at `startup/main_docker.cpp` — the upstream Release default `main_daemon.cpp` forks and would make PID 1 exit immediately.

`Dockerfile` copies this file over the unpacked upstream tree after `mini_project.sh`. When bumping `PAOZHU_REF`, refresh the snapshot and re-apply those two changes; the pinned upstream source still supplies everything else the file globs.

`src/mini_project.sh` is pinned for the same reason. Upstream `25104601` aborts its Step 2 under `set -euo pipefail`: `left=$(grep -c ...)` returns 1 once no RBAC markers remain in the stripped `startup/main_dev.cpp`, so the ORM/view layers are never cleared. The checked-in copy adds `|| true` to that single assignment (verified end-to-end); refresh it together with the CMakeLists snapshot when bumping `PAOZHU_REF`.

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
- `/async-db` and `/fortunes` use `orm::db_conn("pg")` with `co_await async_query()` plus small `set_val` row types instead of a generated ORM model — `mini_project.sh` empties `orm/` and `models/`. paozhu's own Asio Postgres driver (SCRAM-SHA-256) is compiled into the binary, so no `libpq` is needed. Both handlers share an async gate that caps in-flight queries below `DATABASE_MAX_CONN`, because the upstream pool grows on demand without honouring `maxpool`.
- `/fortunes` renders the HTML per request in the handler: `mini_project.sh` also empties `view/` and `viewsrc/`, so `peer->view()` has no template to load. The runtime row, byte-ordinal sort and HTML escaping live in `src/controller/src/db.cpp`.
- Every `//@urlpath` handler in `arena.cpp` and `db.cpp` uses the coroutine form (`asio::awaitable<std::string>` + `co_return ""`), so `paozhu_pre` registers them all through `co_reg`. Only the DB routes really suspend (`co_await async_query()`); the CPU/static handlers have no `co_await` but share the same handler shape.
- paozhu streams raw (`text/plain`) POST bodies to a temp file rather than exposing them in `httppeer::rawcontent`. `arena_baseline11` reads that file and unlinks it immediately; otherwise a POST-heavy run would fill `/app/temp` faster than `httpwatch` sweeps it.
- Only the `[default]` site section is configured, so every `Host` / SNI falls back to site 0.
- `usehtmlcache` is intentionally absent from both conf files; a present key enables the disk pre-check for dotted URLs.
- The two processes use separate `temppath` / `logpath` directories so they never race on scratch files.
- `PAOZHU_REF` selects the upstream revision. The Dockerfile uses a direct `codeload.github.com` tarball URL: `github.com/.../archive/...` 302-redirects to codeload and that hop is blocked on some networks.
- On slow or offline networks, ship a source archive in the build context instead of downloading it: `git -C /Users/hzq/paozhu archive --format=tar.gz --prefix=paozhu-<sha>/ -o frameworks/paozhu/vendor/paozhu-src.tar.gz HEAD`. The Dockerfile prefers `vendor/paozhu-src.tar.gz` when present. The archive is ~36 MB and is deliberately not checked in.
- `APT_MIRROR` is an optional build arg for networks where `deb.debian.org` is slow, e.g. `--build-arg APT_MIRROR=mirrors.aliyun.com`; empty keeps the distro default.
- Local development: `docker build -t httparena-paozhu frameworks/paozhu && VALIDATE_SKIP_BUILD=1 ./scripts/validate.sh paozhu`. Without `VALIDATE_SKIP_BUILD=1`, `validate.sh` rebuilds with `--no-cache` and repeats the full C++ compile. `PAOZHU_REF` can be overridden with `--build-arg PAOZHU_REF=<sha-or-branch>`.
- Measured on a 4-core / 16 GB Ubuntu 26.04 host with `PAOZHU_REF=25104601` ("Add http1 post chunked"): `validate.sh paozhu` reports **62 passed, 0 failed**. All three chunked POST checks now pass (`POST /baseline11` with a chunked body and both fragmented chunked-pipeline cases), alongside `async-db`, `fortunes` and `json-h2c` (all 11 of their checks pass; the DB profiles use a `postgres:18` sidecar). TLS verdict **pass**. A 300-request / 64-parallel `/async-db` plus 150-request / 64-parallel `/fortunes` smoke run returned 200 for every request with 129 live PG connections. Upstream `http_parse.cpp` now decodes `Transfer-Encoding: chunked` into `peer->files["rawcontent"]["tempfile"]`, which is exactly what `raw_body()` in `arena.cpp` reads, so no entry-side change was needed; `40098` is only returned for HTTP/1.0 or malformed transfer encodings.
