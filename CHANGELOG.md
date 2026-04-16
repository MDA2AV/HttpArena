# Changelog

Notable changes to test profiles, scoring, and validation.

## 2026-04-16

### Production Stack — JWT auth, HybridCache, 10K-item CRUD

Major rework of the `production-stack` profile. The test now models a realistic CRUD API with stateless JWT authentication, a three-tier cache hierarchy under real pressure, and concurrent read+write load.

**Auth: session cookies → JWT HMAC-SHA256.** The shared Rust authsvc (`frameworks/_shared/authsvc/`) was rewritten from a Redis session-lookup service to a stateless JWT verifier. Every `/api/*` request triggers a real HMAC-SHA256 signature verification — no caching at authsvc or at the nginx edge. Dependencies changed from `deadpool-redis` + `redis` + `dashmap` to `hmac` + `sha2` + `base64`. The JWT is pre-generated at `data/jwt-token.txt` with a shared secret. This change was driven by the discovery that Redis-backed session auth was bottlenecked by Redis's single-threaded data path at ~60K rps, and all caching workarounds (authsvc DashMap, nginx proxy_cache) made authsvc's CPU reading 0% — meaning the test was no longer measuring auth cost at all.

**Cache rules.** The type rules require cache-aside behavior (check cache → miss → DB → populate with ≤1s TTL, invalidate on write) but the **cache implementation is the framework's choice** — in-process, Redis-only, two-tier, or framework-native caching are all allowed. The cache strategy is part of the competition.

**Working set: 10 IDs → 10,000 IDs.** `requests/production-stack-reads.txt` expanded from 20 URIs to 20,000 URIs with 10,000 unique item IDs. This exercises the cache hierarchy realistically: at ~250K rps with 1-second TTL, ~92% of item reads hit L1, ~5% hit L2 (Redis), ~3% fall through to Postgres. Previously with 10 IDs, everything stayed in L1 permanently and Postgres was never queried — the test was measuring "in-memory hashmap lookup" instead of "cache-aside under pressure."

**CRUD writes via split h2load.** Two h2load instances run in parallel: one for GETs (reads), one for POSTs (writes with a JSON body). h2load can't mix HTTP methods in one invocation, so `h2load_run` in `scripts/lib/tools/h2load.sh` detects a `--split--` sentinel in the argv, forks two processes on the same cpuset, and combines their output. `h2load_parse` sums 2xx counts from both sections. Write targets are 20 IDs (1–20) overlapping with the read working set, creating realistic cache churn on hot items.

**CPU split tuning.** Empirically tuned to edge 15 / cache 1 / authsvc 4 / server 12 (physical cores). Key findings during tuning:
- authsvc scales linearly with cores for JWT crypto (HMAC-SHA256 is embarrassingly parallel)
- BUT stealing cores from server or edge to give to authsvc often makes total throughput WORSE because downstream services can't keep up
- A cliff exists at 5 physical cores for authsvc on the reference hardware (likely CCX/L3 cache boundary crossing)
- The optimal split is where edge (~97%), authsvc (~94%), and server (~74%) are all running hot simultaneously

**Postgres on tmpfs.** `scripts/lib/postgres.sh` now starts the sidecar with `--tmpfs /var/lib/postgresql/data:rw,size=2g`. Postgres WAL + data files live in RAM, not a Docker anonymous volume. This fixed two problems: (1) eliminated a ~70MB/run volume leak that accumulated to 22GB over dozens of iterations, and (2) dramatically improved write throughput (POST /api/items from ~700 rps to ~20K+ rps) because `fsync` is a memcpy instead of a disk I/O.

**Docker resource leak fixes.** `postgres_stop` and `framework_stop` now use `docker rm -f -v` (the `-v` deletes attached anonymous volumes). `cleanup_all` in both `benchmark.sh` and `benchmark-lite.sh` runs `docker volume prune -f` and `docker image prune -f` on both startup and exit.

See `frameworks/aspnet-minimal_nginx/README.md` for the reference entry's implementation details (HybridCache, CPU split tuning findings, etc.).

## 2026-04-15

### Production Stack — initial four-service profile

**Four-service compose** (`compose.production-stack.yml`):

- `edge` — reverse proxy, TLS termination, static file serving, `auth_request` for `/api/*`
- `cache` — Redis 7 with a pre-seed entrypoint that loads 4 sessions + 4 users + 4 products before the stack reports ready
- `authsvc` — **shared Rust sidecar** (axum + deadpool-redis) living at `frameworks/_shared/authsvc/`. One endpoint: `GET /_auth` that extracts `session=<token>` from the Cookie header, does a single Redis `GET session:<token>`, and returns 200 + `X-User-Id` header on hit or 401 on miss. Every production-stack entry builds and uses this binary unmodified — framework code never sees authentication logic
- `server` — the framework being benchmarked. Exposes `/public/baseline`, `/public/json/{count}` (unauth), `/api/products?id=N` (cache-aside: Redis → miss → Postgres `SELECT FROM items` → `SETEX` writeback), `/api/me` (reads `X-User-Id` set by edge, does `GET user:{id}` in Redis)

**Why this shape**:

- **Auth at the edge, not per-framework** — prevents the test from becoming a JWT-library benchmark. Frameworks only read `X-User-Id` as a trusted header, never parse cookies or verify tokens
- **Cache-aside at exactly one endpoint** (`/api/products`) — bounds Redis-client-library variance. A framework only needs to implement `GET` + `SETEX` + fallthrough once
- **Pre-seeded Redis** (`data/redis-seed.txt` + `data/redis-entrypoint.sh`) — the benchmark measures warm-cache steady state, not cold-start. Every `/api/*` request hits a pre-populated key

**Workload** (20 URIs round-robin, `h2load -m 32`, `Cookie: session=bench-session-001` on every request):

| Category | Count | Weight | Handled by |
|---|---|---|---|
| `/static/*` | 6 | 30% | edge (disk, with `gzip_static`) |
| `/public/json/{count}` | 5 | 25% | server |
| `/public/baseline?a=N&b=M` | 3 | 15% | server |
| `/api/products?id={1..4}` | 4 | 20% | edge → authsvc → server (cache-aside) |
| `/api/me` | 2 | 10% | edge → authsvc → server (Redis read) |

**Validation** (10 new checks in `validate.sh::_validate_production_stack`):

- HTTP/2 negotiation, static Content-Type, static size, public baseline fixed + random anti-cheat, `/public/json/25` count/total correctness
- **Auth wall**: `/api/products` without a cookie → 401, with a bogus cookie → 401
- **Authenticated path**: `/api/products?id=1` with `session=bench-session-001` → returns `id=1`; `/api/me` with same cookie → returns user JSON with `id=42` (verifying the seeded session-001 → user-42 chain works end-to-end through authsvc → X-User-Id → Redis user lookup)

**CPU split** is the entry's choice, 64 logical total across 4 services. The reference entry uses `edge: 16 / cache: 4 / authsvc: 4 / server: 40`.

**Scoring**: plain rps (no template split, no bandwidth gain, no composite weighting beyond the standard normalize-and-average path).

**Reference entry**: `frameworks/aspnet-minimal_nginx/` — extended to subscribe to both `gateway-64` and `production-stack`:

- `meta.json` — `tests: ["gateway-64", "production-stack"]`
- `Program.cs` — kept existing gateway-64 routes, added optional `StackExchange.Redis` connection, new `/public/*` and `/api/*` routes
- `aspnet-minimal_nginx.csproj` — added `StackExchange.Redis 2.8.16`
- `proxy-production/nginx.conf` (new) — nginx edge with `auth_request /_auth` + `$upstream_http_x_user_id` capture + `proxy_set_header X-User-Id $auth_user_id`; separate `upstream backend` and `upstream authsvc` blocks with keepalive pools
- `compose.production-stack.yml` (new) — 4 services, pinned cpusets, host networking, depends_on chain (cache → authsvc/server → edge)

Validated 22/22 passing on first run (12 gateway-64 checks + 10 production-stack checks on the same entry).

### `scripts/lib/gateway.sh` — generalized for multi-container compose profiles

The module name is still "gateway" but it now covers any multi-container profile (gateway-64, gateway-h3, production-stack). New helper `_gateway_expected_containers` returns per-profile expected container count (2 for gateway-*, 4 for production-stack); the post-up warning is now profile-aware instead of hardcoding "expects 2 containers".

`scripts/benchmark.sh`, `scripts/validate.sh`, and the early test-gate checks (postgres sidecar, cert mount, static volume, `GATEWAY_ONLY` detection, docker_args host networking) all updated to recognize production-stack alongside the gateway profiles.

## 2026-04-14

### Gateway-H3 — new h3-at-edge profile added

New `gateway-h3` profile: same two-service proxy + server shape as `gateway-64`, same 20-URI mix, same 64-CPU budget, but with **HTTP/3 over QUIC at the edge** instead of HTTP/2 over TCP. Measures QUIC termination efficiency and h3 stream multiplexing through a proxy in a realistic mixed workload.

**Shape**:

- Conn counts: `64, 256` (lower than gateway-64 because h3 has more per-connection overhead)
- Same endpoint surface as gateway-64 (`/static/*`, `/baseline2`, `/json/{count}`, `/async-db`), same weights (6 / 4 / 7 / 3 → 30 / 20 / 35 / 15 %)
- Load generator: `h2load-h3` with `--alpn-list=h3`, `-m 32`, `-H "Accept-Encoding: br;q=1, gzip;q=0.8"`
- Compose file: `compose.gateway-h3.yml` alongside the legacy `compose.gateway.yml` (kept under its original name for back-compat with gateway-64 entries)

**Reference entry** — new `frameworks/aspnet-minimal_caddy/`:

- Caddy edge, stock `caddy:2-alpine` (h3 out of the box, no custom build)
- Caddyfile: `protocols h1 h2 h3`, `file_server { precompressed br gzip }` for `/static/*`, `reverse_proxy` with 2048 keepalive pool to localhost:8080
- Reuses `Handlers.cs` / `AppData.cs` / `Models.cs` from `aspnet-minimal/` via the same COPY-from-repo-root pattern aspnet-minimal_nginx uses
- Compose split: proxy `0-19,64-83` (20 physical) / server `20-31,84-95` (12 physical)

**Scripts**:

- `scripts/lib/profiles.sh` — new `[gateway-h3]="1|0|0-31,64-95|64,256|gateway-h3"` entry; added to `PROFILE_ORDER`; `endpoint_tool` routes `gateway-h3` to `h2load-h3`
- `scripts/lib/tools/h2load-h3.sh` — new `gateway-h3` branch reusing `requests/gateway-64-uris.txt` (URIs are identical; only the edge protocol differs)
- `scripts/lib/gateway.sh` — `gateway_up` / `gateway_down` / `gateway_service_names` now take a profile argument. `_gateway_compose_file` resolves `compose.<profile>.yml` for gateway-h3 while preserving the legacy `compose.gateway.yml` name for gateway-64. Added `GATEWAY_ACTIVE_PROFILE` / `GATEWAY_ACTIVE_FRAMEWORK` state so the EXIT trap tears down whichever stack was last started without needing to be told
- `scripts/benchmark.sh` — case branch covers both gateway profiles; postgres sidecar check includes gateway-h3; template-split block (6/4/7/3) shared between gateway-64 and gateway-h3 because both use the same URI file
- `scripts/validate.sh` — factored the 150-line gateway-64 validation body into `_validate_gateway(profile, compose_file, docs_url)` and called it twice, once per profile. gateway-h3 validation uses `curl --http2` (not `--http3`) because QUIC-enabled curl isn't widely available; since h3-capable proxies also answer h2 on the same port, endpoint correctness is still covered. Actual h3 path is exercised at benchmark time by h2load-h3 — if h3 is broken, rps will be zero and visible immediately

**Docs** — new section `docs/test-profiles/h3-gateway/`:

- `_index.md` + `gateway-h3/_index.md` + `gateway-h3/implementation.md` + `gateway-h3/validation.md`
- Implementation page explains the h3-specific differences from gateway-64: no head-of-line blocking at TCP, userspace QUIC framing, per-packet encryption, UDP send/recv overhead, 0-RTT and connection migration. Lists proxy options: Caddy (easiest, h3 out of the box), nginx 1.25+ with `ngx_http_v3_module` (requires custom build), Envoy, HAProxy 2.8+

**Leaderboard**:

- `layouts/shortcodes/leaderboard-h3-gateway.html` — cloned from h2-gateway shortcode, namespaced `h3gw` throughout
- `layouts/shortcodes/leaderboard-composite.html` — gateway-h3 added to profiles slice (conn counts 64/256, scored); proto color map gets `h3gw: #22c55e` matching h3 baseline
- `content/leaderboard/_index.md` — new "H/3 Gateway" tab, wrapper div, dlConfig entry, wrappers map, MutationObserver list

Validated 12/12 passing on first run.

### Gateway-64 — two-service spec tightened, workload rebalanced, rps honesty fix

**Spec narrowed** to exactly one architecture: one proxy + one server. Previously the docs allowed "any architecture" (single-tier, three-tier, load-balanced, split-proxy, multi-server specialization). That freedom made entries incomparable and invited architectural creativity instead of tuning. Now:

- Exactly two services (`proxy` + `server`)
- Proxy **must** serve `/static/*` directly from disk (no forwarding to server)
- Server **must** serve `/baseline2`, `/json/{count}`, `/async-db`
- Proxy **must** terminate TLS at the edge
- No caches, no load balancers, no additional sidecars beyond the two services

`scripts/lib/gateway.sh` warning tightened from "expected ≥2 containers" to "expects exactly 2 containers" for gateway-* profiles. Implementation docs rewritten to a single architecture diagram and example, deleting the "three-tier", "no proxy", "split proxy", "multi-server specialization" examples.

**Workload rebalanced** from 12 / 3 / 3 / 2 (60 / 15 / 15 / 10 %) to **6 / 4 / 7 / 3 (30 / 20 / 35 / 15 %)**. The new mix is JSON-weighted because server-side compute is the most expensive part of the stack; static serving still keeps the proxy's I/O path under meaningful load; baseline measures raw forwarding efficiency; async-db is the smallest slice because it's latency-bound on the Postgres round-trip rather than CPU-bound on either service. `requests/gateway-64-uris.txt` rewritten with 6 diverse static files (CSS/JS/HTML/WebP), 4 distinct baseline parameter pairs (defeats URI-keyed caches), 7 JSON counts (1/5/10/15/25/40/50 — same ladder as h1-isolated JSON), 3 async-db limits.

**Composite template split** in `scripts/benchmark.sh` updated to match: `tpl_static = total * 6/20`, `tpl_baseline = total * 4/20`, `tpl_json = total * 7/20`, `tpl_async_db = total * 3/20`. Same split shared between gateway-64 and gateway-h3 since they use the same URI file.

**Connection counts iterated during tuning**: started at `256, 1024`, moved through `64, 256` (discovering that on h2 loopback the proxy handles lower conn counts better because `-m 32` streams already provide sufficient multiplexing), landed at **`512, 1024`**. Both points are kept to show scaling behavior: 512 is the efficient regime, 1024 is "what happens when you push past sanity".

**h2load `-m` dropped from 100 to 32** (gateway-64 and static-h2 only, not baseline-h2 or the gRPC profiles). At `-c 64 -m 100` the stack was juggling 6400 in-flight requests on every poll, with ~960 async-db requests fighting for 256 Postgres pool slots — measuring "how well does this stack handle pg pool starvation" instead of the intended mix. `-m 32` halves the in-flight count to a realistic load while still exercising h2 multiplexing meaningfully.

**`H2THREADS` dropped globally from 128 to 64** in `scripts/lib/common.sh`. The load-gen pin (`GCANNON_CPUS=32-63,96-127`) is 64 logical CPUs; running 128 threads meant 2× context-switch overhead on userspace-bound work. Now matches `THREADS` and `H3THREADS`.

**Rps honesty fix**: `h2load_parse` and `h2load_h3_parse` now compute `rps = status_2xx / duration_secs` instead of grabbing the `finished in Xs, Y req/s` number. h2load's own number counts all completed requests including 4xx / 5xx, which silently inflated results when the server was broken. During tuning we discovered this the hard way: `aspnet-minimal_nginx/Program.cs` was registering `/json` (no count route parameter) while the shared `Handlers.Json` expected `int count`, so every `/json/10` / `/json/25` / `/json/50` request returned 404 from the ASP.NET router. h2load reported this as "180 K rps total, but 35% 4xx" and the benchmark was treating the 180 K as the real number. Fixed the route (`/json` → `/json/{count}`) and patched the parser so this class of bug can't silently inflate numbers again.

**Stale-image fix**: `scripts/lib/gateway.sh::gateway_up` now does `docker compose up --build -d` instead of `up -d`. Previously the benchmark script reused whatever image was in the daemon's cache regardless of source changes; an edit to Program.cs could ship silently without being rebuilt, causing the exact 4xx issue above. `validate.sh` was already using `--build`, which is why validation passed while the benchmark was silently running stale code.

**nginx proxy tuning** in `frameworks/aspnet-minimal_nginx/proxy/nginx.conf`:

- `keepalive 1024 → 2048` (40 workers × 2048 = 81920 upstream slots, 5× the peak 16384 in-flight at `1024 conns × 32 streams`)
- Per-upstream `keepalive_requests 100000` and `keepalive_timeout 300s` — at 80 K+ rps per worker the default 10 K recycle fires every 0.125s, causing unnecessary TCP handshakes to localhost. 100 K keeps connections alive ~1.25s between recycles
- `gzip_static on` + `gzip_vary on` — serve `.gz` sidecar files from `/data/static/` when the client advertises `Accept-Encoding: gzip`. Previously nginx served uncompressed `app.js` (~200 KB raw) every time even though `app.js.gz` was right there on disk. Changes the `/static/*` path from "compress every request" to "sendfile the prebuilt bytes", at zero CPU cost

**CPU split tuning**: aspnet-minimal_nginx compose moved from 8/24 through 16/16 → 20/12 → 24/8 → 26/6 and back to 20/12 physical-core split between proxy and server (`proxy: "0-19,64-83"` / `server: "20-31,84-95"`). Leaving the entry at 20/12 as a reasonable default; entries are free to pick their own split.

### `scripts/benchmark.sh` — per-container CPU breakdown for multi-container runs

`scripts/lib/stats.sh` now samples per-container (tagged with a snapshot counter) instead of summing at sample time. At stats_stop we derive two things:

- Aggregate: `STATS_AVG_CPU` = mean of per-snapshot CPU sums; `STATS_PEAK_MEM` = max of per-snapshot memory sums (unchanged behavior — `results/*.json` still gets the stack-wide total)
- Per-container breakdown: new `STATS_BREAKDOWN` string formatted like `"proxy: 4200% 1.2GiB | server: 1200% 512MiB"` using the service name extracted from compose's `<project>-<service>-<index>` pattern

`scripts/benchmark.sh` and `scripts/benchmark-lite.sh` print the breakdown as a second `info` line whenever it's populated (i.e. multi-container runs). Single-container runs suppress it because it would just duplicate the aggregate. Useful for spotting which container is actually the bottleneck during gateway / production-stack tuning — you can now see at a glance whether the proxy is saturated while the server has headroom (or vice versa).

### `scripts/benchmark.sh` — h2load thread-spawn noise suppressed

The trimmed-output filter at the run-display stage now drops `spawning thread #N` and `Warm-up phase is over for thread #N` lines alongside the existing ghz/h2load-h3 warm-up noise. At h2load's 64-thread worker pool this is 128+ lines of boilerplate per run. Applied to both `benchmark.sh` and `benchmark-lite.sh`.

### Raw load-generator logs removed

`scripts/benchmark.sh` and `scripts/benchmark-lite.sh` no longer write per-run raw load-generator output to `site/static/logs/<profile>/<conns>/<framework>.<tool>.run<N>.txt`. The website only links to `${framework}.log` (docker logs) and the per-round files were invisible pollution that ended up tracked in git. The `save_result` block still captures `docker logs $CONTAINER_NAME` to the same directory — that's the file the "Docker logs →" link in the leaderboard popup actually points at. 63 stale run.txt files from earlier iterations were `git rm`'d.

### JSON Compressed composite — compression ratio gain

`json-comp` column on the composite leaderboard now applies a compression-weighted scoring formula, mirroring the legacy `/compression` test. For each framework the handler computes bytes-per-request (`avg_bandwidth / avg_rps`), the field minimum `minBpr` sets the reference, and every framework's effective rps becomes `rps × (minBpr / myBpr)²`. The quadratic exponent is deliberate: doubling the response size quarters the score. Rewards frameworks that pick smaller compression outputs (brotli over gzip, or higher gzip levels) even when raw rps is slightly lower.

Applied in three places in `layouts/shortcodes/leaderboard-composite.html`: the per-profile normalization block (recomputes `maxRpsByProfile['json-comp']` from the adjusted values), the top-3 badge loop (so medals reflect the composite score, not raw rps), and the per-framework score loop (sets `effectiveRps = rps × ratio²` for json-comp specifically).

Also added to the per-profile `json-comp` table on the main leaderboard: new **Score** column (colored green ≥80 / yellow 50–80 / red <50) replaces the bar, new **BW/req** column shows bytes-per-response. Sort is by Score, Best panel picks max score per framework across conn counts. `json-comp` entries are **re-ranked** by score, not raw rps.

Composite popup no longer shows raw rps in parens for json-comp (it was misleading — the displayed score doesn't track rps there). Every other profile still shows it.

Docs: `docs/test-profiles/h1/isolated/json-compressed/implementation.md` has a new **Scoring** section explaining the formula, the quadratic penalty, how the per-profile Best panel differs from the composite column (independent per-conn-count normalization vs. across-conn-count averaging), and what "rewards better ratio" means in practice. `docs/scoring/composite-score.md` has a new **Exception: JSON Compressed** paragraph under Step 2 pointing readers at the full explanation.

## 2026-04-13

### Elysia — PR 489 rebuilt on top of current main

PR 489 (Elysia framework by @SaltyAom) was re-applied from the original commit (`7b1993d`) with the four minimum patches needed for it to run cleanly against the current benchmark shape. The original submission shipped a non-working cluster setup + SQLite handler; rather than tweaking it incrementally, the rebuild restores SaltyAom's architecture and applies only what's required.

**Patches on top of `7b1993d`**:

- **Fork double-loop fixed** — `if (primary) { for loop fork; } else { startup; }` instead of N iterations both forking and running startup. Original structure caused each worker to run startup N times
- **SQLite removed** — dropped `bun:sqlite`, `/data/benchmark.db` loader, and `/db` route (that test no longer exists in the benchmark)
- **Static handler rewritten** — replaced `@elysiajs/static` (dynamic mode doesn't set Content-Type in current Elysia versions) with a direct `Bun.file()` handler that sets `content-type` from `file.type`. Simpler and actually works
- **Upload handler** — destructure `body` from context instead of reading `request.body` stream (was always producing empty responses because the stream was consumed by the parser)
- **async-db result access** — `result.length` / `result.map(...)` (Bun.SQL returns an array directly; `result.rows` is undefined — SaltyAom's code expected a pg-style response shape)
- **Postgres pool sizing** — per-worker `max` = `floor(min(DATABASE_MAX_CONN, 240) / workers)` so `workers × perWorker` stays under Postgres `max_connections`. Without this the cluster's 64 workers opened 64 × default-pool-size connections and got rejected with "too many clients already"
- **pg.connect()** fire-and-forget (no `await`) to avoid top-level `await` inside an `else` block — `bun build --compile` can't handle it

Validation: 23/23 passing on first benchmark run.

### Workerman — Pgsql init guard

`frameworks/workerman/Pgsql.php::init()` previously connected to Postgres unconditionally in `onWorkerStart`. Profiles that don't need a database (baseline, upload, static, json) don't set `DATABASE_URL`, so every worker hit a connection refused on hardcoded `localhost:5432` fallbacks and died. Workerman reported "Start success" because the listeners bound before workers died, but nothing served requests — hence the silent "server did not come up for baseline" warning in the benchmark log.

Fix: early return from `init()` when `DATABASE_URL` is unset; wrap the PDO connect in try/catch so transient DB failures don't crash the worker; `query()` returns an empty `{items:[], count:0}` JSON when the prepared statement is null. Dropped the dead `reConnect()` helper and deleted the unused `Db.php` file (SQLite remnant). `$https->count = (int) shell_exec('nproc')` — was previously assigning the trailing-newline string. Removed `ENV PROCESS_MULTIPLIER=1` and `ENV EVENT_LOOP=Select` from the Dockerfile — neither is referenced by `server.php` and `EVENT_LOOP=Select` was actively misleading (Workerman auto-selects `event` since the image installs `pecl event-3.1.4`).

Validation: 23/23 passing; benchmark: 2.81M rps at baseline-4096c (was crashing before).

## 2026-04-12

### Noisy test — removed

The `noisy` (resilience) test profile has been removed entirely. It previously mixed valid baseline requests with malformed noise (bad paths, bad `Content-Length`, raw binary, bare CR, obs-fold, null bytes) and scored only 2xx responses. The profile was reference-only (not scored), and the insight it provided — which frameworks gracefully reject garbage traffic — is already exercised implicitly by the `baseline` test with realistic request shapes.

**Removed:**
- `noisy` profile from `benchmark.sh`, `benchmark-lite.sh`, and the Windows variants (profile entry, `PROFILE_ORDER`, readiness-check branch, load-gen dispatch branch)
- Resilience block from `validate.sh` / `validate-windows.sh` (bad method + post-noise checks)
- `noisy` from `inner/benchmark-{h1,test,per-test}.sh` profile lists
- Test-profile documentation at `docs/test-profiles/h1/isolated/noisy/`
- Shortcode references in `leaderboard-h1-workload.html`, `leaderboard-h1-isolated.html`, `leaderboard-composite.html` (including the `lb-row-noisy` CSS class + JS branches)
- Landing page card and references in scoring/composite, running-locally/configuration, and add-framework/meta-json docs
- Result directories (`results/noisy/`), site data files (`site/data/noisy-{512,4096,16384}.json`), and `noisy-*` keys from `site/data/rounds/2.json`

The `requests/noise-*.raw` files (bad headers, binary, bare CR, etc.) remain on disk as a reference for anyone who wants to exercise resilience paths manually.

### JSON Compressed profile — added to the website

The `json-comp` profile was running in scripts but wasn't rendered anywhere in the site. Now:

- **Leaderboard shortcodes**: `leaderboard-h1-isolated.html` has a new dict entry (JSON Compressed, conns 512/4096/16384); `leaderboard-composite.html` scores it alongside the plain `json` profile (scored, not engine-scored, same weight pattern).
- **Dedicated docs page**: `docs/test-profiles/h1/isolated/json-compressed/` with `_index.md`, `implementation.md` (endpoint `/json/{count}?m={multiplier}`, counts × multiplier pairs, compression rules, parameters), and `validation.md` (the three `validate.sh` checks: `Content-Encoding` present with `Accept-Encoding`, body correctness across `(12,9) / (31,4) / (50,1)`, no `Content-Encoding` without `Accept-Encoding`).
- **Landing page card**: new "JSON Compressed" card in `content/_index.md` next to JSON Processing, pointing at `/json/{count}?m=N`.
- **Docs index**: new card in `docs/test-profiles/h1/isolated/_index.md`.
- **Scoring table**: added to `docs/scoring/composite-score.md` as a scored H/1.1 Isolated profile.
- **Running-locally config** and **add-framework/meta.json** docs updated with the new profile row.

### `json-compressed` load-generator dispatch branch added

`scripts/benchmark.sh` previously declared `[json-comp]="1|0|0-31,64-95|512,4096,16384|json-compressed"` but had **no matching `elif [ "$endpoint" = "json-compressed" ]` branch** in the load-gen dispatch. Runs fell through to the default `else` clause (three-raw baseline rotation with no `Accept-Encoding`), so all prior `results/json-comp/*` numbers were indistinguishable from `baseline` — same rps, same ~300 MB/s, same 2-byte "55" responses.

Fixed by adding the branch (and mirroring into `benchmark-lite.sh` / `benchmark-lite-windows.sh`):

```bash
elif [ "$endpoint" = "json-compressed" ]; then
    gc_args=("http://localhost:$PORT"
        --raw "$REQUESTS_DIR/json-gzip-{1,5,10,15,25,40,50}.raw"
        -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline" -r 25)
```

The `json-gzip-*.raw` files (which already existed in `requests/`) contain the same 7 `(count, m)` pairs as the plain `json-*.raw` variants plus an `Accept-Encoding: gzip, br` header. Post-fix, gcannon reports `Templates: 7` and response bodies carry `Content-Encoding: gzip` or `br` depending on what the framework's compression path produces.

The stale "looks like baseline" `json-comp` result files under `results/json-comp/` and `site/data/json-comp-*.json` were deleted so the next `--save` run produces honest measurements.

### `json-comp` connection counts

`json-comp` moved from `512, 4096` to `512, 4096, 16384` — same pattern as `baseline` and `echo-ws` — to stress the compression path under extreme concurrent-connection pressure where middleware queuing shows up clearly. The 16384c run surfaces differences between frameworks that keep compression state per connection vs. those that allocate per request.

Updated in `scripts/benchmark.sh`, `site/layouts/shortcodes/leaderboard-h1-isolated.html`, `site/layouts/shortcodes/leaderboard-composite.html`, `site/content/docs/running-locally/configuration.md`, and `site/content/docs/test-profiles/h1/isolated/json-compressed/implementation.md`.

### JSON over TLS profile — added (`json-tls`)

New H/1.1 Isolated profile that runs the same `/json/{count}?m=N` workload as the plain `json` profile but transports it over **HTTP/1.1 + TLS** on a dedicated port. Measures how much of a framework's plaintext JSON throughput survives TLS record framing, symmetric cipher work, and ALPN negotiation. No compression — clients send no `Accept-Encoding` so this is pure TLS overhead on top of serialization.

**Shape**:

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /json/{count}?m={multiplier}` |
| Transport | HTTP/1.1 over TLS |
| Port | **8081** (distinct from 8080 plaintext and 8443 H2/H3) |
| ALPN | `http/1.1` only (wrk speaks HTTP/1.1 only) |
| Load generator | **wrk** + `requests/json-tls-rotate.lua` (gcannon has no TLS support) |
| Count × multiplier pairs | `(1,3) (5,7) (10,2) (15,5) (25,4) (40,8) (50,6)` (same 7 pairs as the plain `json` profile) |
| Connections | 4,096 |
| Pipeline / req-per-conn | 1 / 0 (persistent keep-alive) |
| CPU pinning | `0-31,64-95` |
| Certificates | reuses `certs/server.crt` + `certs/server.key` (same as `baseline-h2`) |

**Script plumbing**:

- `scripts/benchmark.sh`: new `H1TLS_PORT=8081`, `[json-tls]` entry in `PROFILES`, added to `PROFILE_ORDER` after `json-comp`, readiness check `https://localhost:$H1TLS_PORT/json/1?m=1`, new wrk dispatch branch
- `scripts/validate.sh`: `H1TLS_PORT=8081`, `needs_h1tls` path that mounts `/certs` + publishes `-p 8081:8081`, new validation block with three checks:
  1. ALPN negotiates HTTP/1.1 (`--http1.1` curl reports `http_version = 1.1`)
  2. Body correctness across `(7,2) / (23,11) / (50,1)` — deliberately different from the `json-comp` pairs `(12,9) / (31,4) / (50,6)` so a framework can't trivially share validation state between profiles
  3. `Content-Type: application/json`
- `requests/json-tls-rotate.lua`: new wrk Lua that round-robins the 7 `(count, m)` pairs, no `Accept-Encoding` header

**Site plumbing**:

- New profile dict in `leaderboard-h1-isolated.html` (conns `4096`) and `leaderboard-composite.html` (scored, not engine-scored)
- Dedicated docs dir `site/content/docs/test-profiles/h1/isolated/json-tls/` with `_index.md`, `implementation.md` (endpoint spec, port, ALPN, certs, parameters table), `validation.md` (the three checks)
- Landing card in `content/_index.md`, new card in `h1/isolated/_index.md`, new row in `running-locally/configuration.md`, `add-framework/meta-json.md`, and `scoring/composite-score.md`

**Framework implementation requirement**:

Each framework that subscribes to `json-tls` must bind a second HTTPS listener on port **8081** with ALPN `http/1.1` (separate from any existing HTTP/2 listener on 8443). The `/json/{count}?m=N` handler itself is shared with the plain `json` profile — no new route needed, just the listener.

- **Pilot**: `aspnet-minimal` (added a second `Kestrel.ListenAnyIP(8081)` with `Protocols = HttpProtocols.Http1` + `UseHttps(…)` alongside the existing `:8443` H1+H2+H3 listener, and `json-tls` in `meta.json`)
- Other frameworks need a similar ~5-10 line addition and `"json-tls"` in their `meta.json` tests array to opt in

### JSON Processing docs — fixed `?m=` inconsistency

The `json-processing/implementation.md` page had a self-contradiction: the "How it works" section said `GET /json/{count}` and `total = price × quantity`, while the example URL and rule text referenced `?m=3` and `total = price * quantity * m`. The load generator has always sent `?m=N` with the 7 fixed multipliers. Docs now consistently describe `GET /json/{count}?m={multiplier}` and enumerate the `(count, m)` pairs `(1,3) (5,7) (10,2) (15,5) (25,4) (40,8) (50,6)` in the parameters table.

## 2026-04-10

### JSON test — variable item count and multiplier

The JSON endpoint changed from `GET /json` to `GET /json/{count}?m=N`, where `count` (1–50) controls how many items the server returns and `m` (integer, default 1) is a multiplier applied to the total field: `total = price * quantity * m`. Each benchmark template uses a different `m` value, making every response unique and preventing response caching. All dataset fields are now integers (no floats) to avoid culture-specific decimal formatting and floating-point rounding issues.

### Compression test — merged into JSON

The standalone `/compression` endpoint has been removed. Compression is now tested through the JSON endpoint by sending `Accept-Encoding: gzip, br` in the request headers. The compression middleware handles on-the-fly compression when the header is present. Two separate benchmark profiles use the same endpoint:
- **json** — no `Accept-Encoding`, measures pure serialization
- **json-compressed** — with `Accept-Encoding: gzip, br`, measures serialization + compression

This eliminates the need for pre-loaded dataset files (`dataset-large.json`, `dataset-{100,1000,1500,6000}.json`) and the separate `/compression/{count}` route.

### Upload test — variable payload size

The upload benchmark now rotates across four payload sizes: 500 KB, 2 MB, 10 MB, and 20 MB (using gcannon `-r 5`). Previously only a fixed 20 MB payload was sent. Validation tests all four sizes. No endpoint change — `POST /upload` still returns the byte count.

### Async DB test — variable limit

The async-db endpoint now accepts a `limit` query parameter: `GET /async-db?min=10&max=50&limit=N`. The benchmark rotates across limits 5, 10, 20, 35, and 50 (using gcannon `-r 25` to balance requests evenly). Validation uses different limits (7, 18, 33, 50) **and** different price ranges (`min`/`max`) per request to prevent hardcoded responses. The SQL `LIMIT` clause is now parameterized instead of hardcoded to 50.

### All data fields changed to integers

All numeric fields in the datasets and database are now integers — no floats or doubles anywhere. This eliminates floating-point rounding inconsistencies, locale-specific decimal formatting issues, and type mismatch errors with parameterized database queries.

- **dataset.json**: `price` (was float → int 1–500), `rating.score` (was float → int 1–50)
- **dataset-large.json**: same changes across 6,000 items
- **pgdb-seed.sql**: `price` and `rating_score` columns changed from `DOUBLE PRECISION` to `INTEGER`
- **JSON `total` field**: now `price * quantity * m` — pure integer multiplication, no rounding needed
- All frameworks updated: query parameters, DB readers, and model types changed from float/double to int/long

### TCP Fragmentation test — removed

The `tcp-frag` test profile has been removed. With loopback MTU now set to 1500 (realistic Ethernet) for all tests, every benchmark already exercises TCP segmentation under production-like conditions. The extreme MTU 69 stress test no longer adds meaningful signal.

### Assets-4 / Assets-16 tests — removed

The `assets-4` and `assets-16` workload profiles have been removed. These were mixed static/JSON/compression tests constrained to 4 and 16 CPUs respectively. The `static` and `json` isolated profiles already cover file serving and serialization independently, and the `api-4`/`api-16` profiles cover resource-constrained workloads.

### Static files — realistic file sizes

Regenerated all 20 static files with varied sizes typical of a modern web application. Files now have realistic size distribution — large bundles (vendor.js 300 KB, app.js 200 KB, components.css 200 KB) alongside small utilities (reset.css 8 KB, analytics.js 12 KB, logo.svg 15 KB). Content uses realistic repetition patterns for compression ratios matching real-world code.

| Category | Files | Size range |
|----------|-------|------------|
| CSS | 5 | 8–200 KB |
| JavaScript | 5 | 12–300 KB |
| HTML | 2 | 55–120 KB |
| Fonts | 2 | 18–22 KB |
| SVG | 2 | 15–70 KB |
| Images | 3 | 6–45 KB |
| JSON | 1 | 3 KB |

Total: ~842 KB original, ~219 KB brotli-compressed, ~99 KB binary.

### Static files — pre-compressed files on disk

All 15 text-based static files now ship with pre-compressed variants alongside the originals:

- `.gz` — gzip at maximum level (level 9)
- `.br` — brotli at maximum level (quality 11)

Compression ratios: gzip 64–93%, brotli 68–94%. These files allow frameworks that support pre-compressed file serving (e.g., Nginx `gzip_static`/`brotli_static`, ASP.NET `MapStaticAssets`) to serve compressed responses with **zero CPU overhead** — no on-the-fly compression needed.

Binary files (woff2, webp) do not have pre-compressed variants since they are already compressed formats.

### Static test — load generator changed to wrk

The H/1.1 static file test now uses **wrk** with a Lua rotation script instead of gcannon. wrk achieves higher throughput on large-response workloads (~20% more bandwidth than gcannon's io_uring buffer ring path), ensuring the load generator is not the bottleneck. The Lua script rotates across all 20 static file paths with `Accept-Encoding: br;q=1, gzip;q=0.8`.

### Loopback MTU set to 1500

All benchmark scripts now set the loopback interface MTU to 1500 (realistic Ethernet) before benchmarking and restore to 65536 on exit. This ensures TCP segmentation behavior matches real-world production networks.

### Static files — compression support

All static file requests now include `Accept-Encoding: br;q=1, gzip;q=0.8`. Compression is **optional** — frameworks that compress will benefit from reduced I/O, but there is no penalty for serving uncompressed.

- **Production**: must use framework's standard middleware or built-in handler. No handmade compression.
- **Tuned**: free to use any compression approach.
- **Engine**: pre-compressed files on disk allowed, must respect Accept-Encoding header presence/absence.

Validation updated: new compression verification step tests all 20 files with Accept-Encoding, verifies decompressed size matches original. PASS if correct, SKIP if server doesn't compress, FAIL if decompressed size is wrong.

### Sync DB test — removed

The `sync-db` test profile (SQLite range query over 100K rows) has been removed. The test was redundant with `json` (pure serialization) and `async-db` (real database with network I/O, connection pooling). At 8 MB, the entire database was cached in RAM regardless of mmap settings, making it essentially a JSON serialization test with constant SQLite overhead.

**Removed:**
- `sync-db` profile from benchmark scripts and validation
- `sync-db` from all 54 framework `meta.json` test arrays
- Database documentation (`test-profiles/h1/isolated/database/`)
- Sync DB tab from H/1.1 Isolated and Composite leaderboards
- `sync-db` from composite scoring formula
- `benchmark.db` volume mount from Docker containers
- Result data (`sync-db-1024.json`)

The `/db` endpoint code remains in framework source files but is no longer tested or scored.
