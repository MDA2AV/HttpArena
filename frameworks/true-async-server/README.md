# true-async-server

[TrueAsync Server](https://github.com/true-async/server) — a native PHP
extension that runs an HTTP/1.1 + HTTP/2 + HTTP/3 server inside the PHP
process. No FastCGI, no separate Caddy / FrankenPHP / nginx in front.
Everything (accept, parse, dispatch to PHP handler, response) happens on
the TrueAsync coroutine event loop in the same OS thread that owns the
connection.

- **Source:** <https://github.com/true-async/server>
- **Engine:** TrueAsync (PHP fork — <https://github.com/true-async/php-src>)
- **Tier:** `tuned`
- **Image:** `trueasync/php-true-async:0.7.0-alpha.13-php8.6`

### Related repositories

| Repo | Purpose |
|------|---------|
| [`true-async/server`](https://github.com/true-async/server) | This extension — the HTTP/1+2+3 server itself (source of `true_async_server.so`) |
| [`true-async/php-src`](https://github.com/true-async/php-src) | PHP 8.6 fork with the TrueAsync coroutine API in core |
| [`true-async/php-async`](https://github.com/true-async/php-async) | `ext/async` — coroutines, `ThreadPool`, `spawn`, PDO connection pool |
| [`true-async/releases`](https://github.com/true-async/releases) | Release pipeline: builds Docker images and Windows ZIPs from the three repos above |
| [`true-async/frankenphp`](https://github.com/true-async/frankenphp) | TrueAsync fork of FrankenPHP (separate framework entry, not used here) |
| [`true-async/xdebug`](https://github.com/true-async/xdebug) | Xdebug fork patched for the TrueAsync runtime |
| [Docker Hub `trueasync/php-true-async`](https://hub.docker.com/r/trueasync/php-true-async) | Pre-built images consumed by this framework's `Dockerfile` |

## How it works

### One process, N event-loop threads

A single PHP process is launched. The main thread reads the dataset
into shared read-only memory, constructs an `HttpServer` from
`HttpServerConfig`, mounts a `StaticHandler` for `/static/`, and
registers a single PHP callback via `addHttpHandler`. Static files
themselves are served from C — the PHP callback never sees them.

The main thread then submits an `Async\ThreadPool` job for each CPU
(`N = available_parallelism()`, overridable via `WORKERS=…`). The job
body just calls `$server->start()` on a thread-transferred copy of the
server object. The transfer copies the registered callbacks and the
listener configuration — there is no shared mutable state between
threads.

Each thread runs its own libuv event loop. There is no master/worker
split: every thread accepts, parses, executes the handler, writes the
response, and recycles the connection. `SO_REUSEPORT` lets all
threads bind the same TCP/UDP ports — the kernel hashes incoming SYNs
across the listening sockets so connections distribute evenly.

### Protocol detection happens once per connection

When bytes first arrive on a plain-TCP listener, a small detector
inspects the first 8+ bytes:

- starts with `PRI ` → HTTP/2 cleartext (h2c) — route into nghttp2.
- starts with an HTTP/1.1 method byte (`G`, `P`, `D`, `H`, `O`, `C`, `T`)
  → HTTP/1.1 — route into the llhttp parser.
- otherwise after 24 bytes → reject as `400 Bad Request` (or h2
  `BAD_CLIENT_MAGIC`).

For TLS listeners, ALPN does the work during the handshake — the server
advertises `[h2, http/1.1]` and the client picks. ALPN result decides
which strategy is installed; no first-byte sniff happens after the TLS
handshake.

For UDP listeners (HTTP/3), packets go directly to the QUIC stack;
ALPN inside the QUIC TLS handshake selects `h3` or fails.

Once the strategy is installed it stays for the lifetime of the
connection — no per-request re-detection.

### Coroutine per request, not per connection

The accept loop pulls one connection. The chosen protocol strategy reads
bytes off the socket and assembles requests:

- HTTP/1.1 — one request at a time, possibly pipelined; for each parsed
  request a fresh PHP coroutine is spawned and given `(HttpRequest,
  HttpResponse)`.
- HTTP/2 / HTTP/3 — every stream is its own request; each opened stream
  spawns a coroutine. Streams on the same connection run truly in
  parallel within the event loop, multiplexed onto the wire by nghttp2 /
  nghttp3.

The coroutine runs the user callback. When the callback awaits I/O
(database, file, sleep), the coroutine yields back to the event loop,
which immediately serves another stream / request. There is no
`pthread_create` per request and no thread pool dispatch; coroutines are
stack-switched in userland.

When the callback returns, `HttpResponse` is committed to the wire
(buffered or streamed depending on whether the handler called `send()`),
the coroutine is disposed, and its arena (`conn_arena`) is reset for the
next request on the same connection.

### Bailout firewall

If the user callback hits a fatal (E_ERROR, OOM, exception during
shutdown) and triggers `zend_bailout`, the protocol strategy catches it
at the request boundary:

- emits a 500 on the failing request,
- logs the PHP cause via SAPI's error pipeline,
- on glibc, dumps the C-level stack via `backtrace(3)` for postmortem,
- keeps the listener and other in-flight requests alive.

This is what makes a single-process server safe to run user PHP code
that may legitimately fatal — one bad handler doesn't take the listener
down.

### Compression pipeline

The response writer transparently compresses bodies that opt in
(`HttpResponse` does not call `setNoCompression()`, MIME is on the
whitelist, body ≥ 1 KiB threshold) when the client's `Accept-Encoding`
allows it. Negotiation is RFC 9110 §12.5.3 (q-values, `identity;q=0`,
`*;q=0`). Encoding runs on streamed chunks, not buffered, so chunked H1
and H2 DATA frames stay efficient. Inbound `Content-Encoding: gzip`
request bodies are decoded transparently with an anti-zip-bomb cap. The
encoder is zlib-ng when available, system zlib otherwise.

`entry.php` enables this middleware via
`HttpServerConfig::setCompressionEnabled(true)`, so the `/json/*`
responses are transparently compressed when the client advertises
`Accept-Encoding: br|gzip` — that's what powers the `json-comp`
profile.

### What `entry.php` actually contains

A `StaticHandler` mount for `/static/` plus a flat PHP dispatcher:

```php
$server->addStaticHandler(
    (new StaticHandler('/static/', '/data/static'))
        ->enablePrecompressed('br', 'gzip')
        ->setEtagEnabled(true)
        ->setOpenFileCache(1024, 60)
);

$server->addHttpHandler(static function ($req, $res) use ($dataset, $datasetCount) {
    $path = $req->getPath();

    if ($path === '/baseline11' || $path === '/baseline2') { ... sum ... }
    if ($path === '/pipeline')                              { ... 'ok' ... }
    if (str_starts_with($path, '/json/'))                   { ... slice + json_encode ... }
    if ($path === '/upload')                                { ... awaitBody ... }
    /* /static/* is served by StaticHandler above; anything else → 404 */
});
```

Order is by request frequency under the validation suite; `/baseline11`
goes first because it's the hottest endpoint across `baseline`,
`pipelined`, and `limited-conn` profiles.

## Listeners (in `entry.php`)

| Port | Protocol | Used by profile |
|------|----------|----------------|
| 8080 | h1 cleartext | `baseline`, `pipelined`, `limited-conn`, `json`, `upload` |
| 8081 | h1 + TLS | `json-tls` |
| 8443 | h1 + h2 + TLS (ALPN) | `baseline-h2` |

## Subscribed profiles

```
baseline, pipelined, limited-conn, json, json-comp, json-tls,
upload, static, static-h2, baseline-h2
```

All ten pass the HttpArena validation suite (39/39 checks) on the
published image.

`static` / `static-h2` are served by the server's built-in C
`StaticHandler` (`addStaticHandler` in `entry.php`), which does
sendfile + per-request precompressed sidecar (`.br` / `.gz`) selection
and an open-file cache — no PHP-level buffering.

`json-comp` uses the server's transparent compression middleware
(`setCompressionEnabled(true)` on the config), which negotiates
brotli / gzip from `Accept-Encoding` automatically.

## Not yet subscribed (work-in-progress)

- `baseline-h2c`, `json-h2c` — HttpArena requires port 8082 to refuse
  HTTP/1.1, but `protocol_mask` in TrueAsync Server is currently
  per-server, not per-listener. Per-listener mask is on the roadmap.
- `async-db`, `crud`, `api-4`, `api-16`, `fortunes` — DB-backed; we ship
  a PostgreSQL adapter (`PostgreSQL.php` via `pdo-async` connection
  pool) but haven't validated the full suite yet.
- `baseline-h3`, `static-h3`, `gateway-h3` — HTTP/3 listener
  (`addHttp3Listener`) is in the server but not yet enabled in
  `entry.php`.

The full feature roadmap lives in
[`FUTURES.md`](https://github.com/true-async/server/blob/main/FUTURES.md)
on the server repo.

## Running locally

```bash
./scripts/validate.sh true-async-server
./scripts/benchmark.sh true-async-server baseline-h2
./scripts/benchmark-lite.sh true-async-server baseline-h2
```

`benchmark-lite.sh` defaults `H2THREADS=nproc/2` so it's friendly to
laptops; `benchmark.sh` is the leaderboard configuration (64 threads on
dedicated hardware).

## Local development build

`build.sh` and `Dockerfile.local` exist for testing un-tagged commits of
`true-async/server` against this framework: they copy a host-built
`php` binary and `true_async_server.so` over the upstream alpha image.
Not used in CI.

## Maintainers

- [@EdmondDantes](https://github.com/EdmondDantes)
