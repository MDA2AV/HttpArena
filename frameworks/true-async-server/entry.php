<?php

declare(strict_types=1);

/*
 * HttpArena entry point for the TrueAsync HTTP server.
 *
 * Architecture (post-bootloader API):
 *   - One PHP process. N worker threads (N = available_parallelism()).
 *   - $config->setWorkers(N)->setBootloader(...) — HttpServer::start()
 *     spawns the worker pool itself, deep-copies the bootloader closure
 *     into every worker, runs it once per worker before the task loop
 *     (the right place for per-worker autoload / DB pool warm-up), then
 *     transfers the server into each worker and awaits all of them.
 *   - SO_REUSEPORT lets the kernel load-balance accept()s across all
 *     worker threads.
 *
 * Override worker count with the WORKERS env var.
 */

use TrueAsync\HttpServer;
use TrueAsync\HttpServerConfig;
use TrueAsync\HttpRequest;
use TrueAsync\HttpResponse;
use TrueAsync\StaticHandler;
use function Async\available_parallelism;

// --- Preload at process start (read once, transferred to all workers) ---

$datasetRaw   = json_decode(file_get_contents('/data/dataset.json'), true);
$datasetCount = count($datasetRaw);

$staticDir = '/data/static';

// --- Runtime knobs ---

$port      = (int)(getenv('PORT') ?: 8080);
$tlsPort   = (int)(getenv('TLS_PORT') ?: 8443);
$h2cPort   = (int)(getenv('H2C_PORT') ?: 8082);
$h3Port    = (int)(getenv('H3_PORT') ?: $tlsPort);
$h3Enabled = getenv('H3_DISABLE') !== '1';
$workers   = (int)(getenv('WORKERS') ?: 0);
if ($workers <= 0) {
    $workers = available_parallelism();
}

$certPath     = '/certs/server.crt';
$keyPath      = '/certs/server.key';
$tlsAvailable = is_readable($certPath) && is_readable($keyPath);

// --- Build the server config ---

$config = (new HttpServerConfig())
    ->addListener('0.0.0.0', $port)
    // Cleartext HTTP/2 prior-knowledge listener — powers baseline-h2c / json-h2c.
    ->addHttp2Listener('0.0.0.0', $h2cPort, false)
    ->setBacklog(2048)
    ->setMaxBodySize(32 * 1024 * 1024)
    // Stream request bodies into per-request queue instead of buffering
    // the whole Content-Length into req->body. Required for /upload to
    // stay within RSS limits under concurrent 20 MiB POSTs (issue #26).
    ->setBodyStreamingEnabled(true)
    // Transparent gzip/brotli middleware — needed for the json-comp profile.
    // Drop both levels to 1 to match Swoole's http_compression_level=1 default
    // and the typical high-RPS arena workload. Encode CPU dominates byte-on-wire
    // here; q=1 keeps ratio acceptable (br q=1 ≈ 1.5 KB vs q=4 ≈ 1.2 KB on the
    // 6.7 KB /json/40 payload) at ~2× faster encode.
    ->setCompressionEnabled(true)
    ->setCompressionLevel(1)
    ->setBrotliLevel(1)
    // Built-in worker pool — HttpServer::start() spawns the pool itself.
    ->setWorkers($workers)
    // Run once per worker before its task loop. The class files contain
    // declarations that must live in every worker's compiler tables.
    ->setBootloader(static function (): void {
        require __DIR__ . '/PostgreSQL.php';
        require __DIR__ . '/SQLite.php';
        require __DIR__ . '/SharedCache.php';
    });

if ($tlsAvailable) {
    // 8081: h1 over TLS for the json-tls and static-tls profiles. 8443: h2 + h1
    // over TLS (ALPN).
    //
    // 8081 is bound first on purpose. validate.sh waits for 8443 before it runs
    // any TLS check and never waits for 8081, so binding 8081 second leaves a
    // window where the static-tls checks fire against a port that is not up yet
    // - which is what happened on CI while passing on a faster machine.
    $config
        ->addListener('0.0.0.0', 8081, true)
        ->addListener('0.0.0.0', $tlsPort, true)
        ->setCertificate($certPath)
        ->setPrivateKey($keyPath)
        // Pin the TLS clear-text-out BIO ring to 64 KiB (#29). This already
        // matches the built-in default, set explicitly so the arena's TLS
        // write-buffer size stays fixed regardless of future default changes.
        ->setTlsBufferBytes(64 * 1024);

    // HTTP/3 over QUIC on the same UDP port — powers baseline-h3 / static-h3.
    // Reuses the TLS cert/key and coexists with h2 on TCP :8443. A 120-iteration
    // back-to-back restart repro (16 and 64 workers) showed 0 startup failures
    // with this listener on — the C listener sets SO_REUSEADDR/SO_REUSEPORT — so
    // it stays always-on. Set H3_DISABLE=1 to skip on builds without H3.
    if ($h3Enabled) {
        $config->addHttp3Listener('0.0.0.0', $h3Port);
    }
}

// Bootloader needs the class files visible in the parent too, otherwise
// the per-worker snapshot of the handler closure cannot resolve the type
// references when the handler is deep-copied alongside the server.
require __DIR__ . '/PostgreSQL.php';
require __DIR__ . '/SQLite.php';
require __DIR__ . '/SharedCache.php';

$server = new HttpServer($config);

// Static-file delivery from C (sendfile + precompressed sidecar selection).
// Powers the `static` and `static-h2` profiles.
if (is_dir($staticDir)) {
    $server->addStaticHandler(
        (new StaticHandler('/static/', $staticDir))
            ->enablePrecompressed('br', 'gzip')
            ->setEtagEnabled(true)
            ->setOpenFileCache(1024, 60)
    );
}

$server->addHttpHandler(
    static function (HttpRequest $request, HttpResponse $response)
        use ($datasetRaw, $datasetCount): void
    {
        $path = $request->getPath();

        // Hottest endpoint in the suite (baseline + pipelined + limited-conn) — check first.
        if ($path === '/baseline11' || $path === '/baseline2') {
            $sum = array_sum($request->getQuery());
            if ($request->getMethod() === 'POST') {
                // Streaming body (issue #26): drain chunks into one buffer
                // before (int) cast. Bench body is small (<8 KiB) so the
                // single-buffer concat stays cheap.
                $body = '';
                while (($c = $request->readBody()) !== null) {
                    $body .= $c;
                }
                $sum += (int)$body;
            }
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'text/plain')
                ->setBody((string)$sum);
            return;
        }

        if ($path === '/pipeline') {
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'text/plain')
                ->setBody('ok');
            return;
        }

        if (str_starts_with($path, '/json/')) {
            $tail = substr($path, 6);
            if ($tail !== '' && ctype_digit($tail)) {
                $query = $request->getQuery();
                $count = min((int)$tail, $datasetCount);
                $mult  = (int)($query['m'] ?? 1);
                if ($mult === 0) {
                    $mult = 1;
                }
                $items = [];
                for ($i = 0; $i < $count; $i++) {
                    $item          = $datasetRaw[$i];
                    $item['total'] = $item['price'] * $item['quantity'] * $mult;
                    $items[]       = $item;
                }
                $response->setStatusCode(200)
                    ->setHeader('Content-Type', 'application/json')
                    ->setBody(json_encode(
                        ['items' => $items, 'count' => $count],
                        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
                    ));
                return;
            }
        }

        if ($path === '/upload') {
            // Streaming-body fast path (issue #26): never materialise the
            // 20 MiB body into a single zend_string. Count chunks as they
            // arrive, peak memory bounded by socket buffer + one chunk.
            $bytes = 0;
            while (($c = $request->readBody()) !== null) {
                $bytes += strlen($c);
            }
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'text/plain')
                ->setBody((string)$bytes);
            return;
        }

        if ($path === '/async-db') {
            $query = $request->getQuery();
            $min   = (float)($query['min'] ?? 10);
            $max   = (float)($query['max'] ?? 50);
            $limit = max(1, min(50, (int)($query['limit'] ?? 50)));
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'application/json')
                ->setBody(PostgreSQL::query($min, $max, $limit));
            return;
        }

        // crud: REST over the same pooled PDO async-db uses, with a cache-aside
        // in front of the single-item read. SharedCache puts it in shared
        // memory, which a per-worker array could not do - each worker thread
        // gets its own PHP context.
        if ($path === '/crud/items') {
            if ($request->getMethod() === 'POST') {
                $raw = '';
                while (($c = $request->readBody()) !== null) {
                    $raw .= $c;
                }
                $body = json_decode($raw, true);
                $json = is_array($body) ? PostgreSQL::crudCreate($body) : null;
                if ($json === null) {
                    $response->setStatusCode(500)
                        ->setHeader('Content-Type', 'application/json')
                        ->setBody('{"error":"insert failed"}');
                    return;
                }
                $response->setStatusCode(201)
                    ->setHeader('Content-Type', 'application/json')
                    ->setBody($json);
                return;
            }
            $query    = $request->getQuery();
            $category = (string)($query['category'] ?? 'electronics');
            $page     = max(1, (int)($query['page'] ?? 1));
            $limit    = max(1, min(50, (int)($query['limit'] ?? 10)));
            $json     = PostgreSQL::crudList($category, $page, $limit);
            if ($json === null) {
                $response->setStatusCode(500)
                    ->setHeader('Content-Type', 'application/json')
                    ->setBody('{"error":"query failed"}');
                return;
            }
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'application/json')
                ->setBody($json);
            return;
        }

        if (str_starts_with($path, '/crud/items/')) {
            $id  = (int)substr($path, strlen('/crud/items/'));
            $key = 'crud:' . $id;

            if ($request->getMethod() === 'PUT') {
                $raw = '';
                while (($c = $request->readBody()) !== null) {
                    $raw .= $c;
                }
                $body = json_decode($raw, true);
                $json = is_array($body) ? PostgreSQL::crudUpdate($id, $body) : null;
                if ($json === null) {
                    $response->setStatusCode(500)
                        ->setHeader('Content-Type', 'application/json')
                        ->setBody('{"error":"update failed"}');
                    return;
                }
                if ($json === false) {
                    $response->setStatusCode(404)->setBody('');
                    return;
                }
                SharedCache::del($key);
                $response->setStatusCode(200)
                    ->setHeader('Content-Type', 'application/json')
                    ->setBody($json);
                return;
            }

            $hit = SharedCache::get($key);
            if ($hit !== null) {
                $response->setStatusCode(200)
                    ->setHeader('Content-Type', 'application/json')
                    ->setHeader('X-Cache', 'HIT')
                    ->setBody($hit);
                return;
            }
            $json = PostgreSQL::crudRead($id);
            if ($json === null) {
                $response->setStatusCode(500)
                    ->setHeader('Content-Type', 'application/json')
                    ->setBody('{"error":"query failed"}');
                return;
            }
            if ($json === false) {
                $response->setStatusCode(404)->setBody('');
                return;
            }
            // The profile reads and writes the same ids, so a long TTL would
            // answer from a copy the writes have already moved past.
            SharedCache::setPx($key, $json, 200);
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'application/json')
                ->setHeader('X-Cache', 'MISS')
                ->setBody($json);
            return;
        }

        if ($path === '/fortunes') {
            $rows   = PostgreSQL::fortunes();
            $rows[] = ['id' => 0, 'message' => 'Additional fortune added at request time.'];
            usort($rows, static fn($a, $b) => strcmp($a['message'], $b['message']));

            $html = '<!DOCTYPE html><html><head><title>Fortunes</title></head>'
                  . '<body><table><tr><th>id</th><th>message</th></tr>';
            foreach ($rows as $row) {
                $html .= '<tr><td>' . $row['id'] . '</td><td>'
                       . htmlspecialchars($row['message'], ENT_QUOTES | ENT_HTML5, 'UTF-8')
                       . '</td></tr>';
            }
            $html .= '</table></body></html>';

            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'text/html; charset=utf-8')
                ->setBody($html);
            return;
        }

        if ($path === '/sqlite-db') {
            $query = $request->getQuery();
            $min   = (float)($query['min'] ?? 10);
            $max   = (float)($query['max'] ?? 50);
            $limit = max(1, min(50, (int)($query['limit'] ?? 50)));
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'application/json')
                ->setBody(SQLite::query($min, $max, $limit));
            return;
        }

        // /static/* is handled by the StaticHandler registered above;
        // anything reaching here under /static/ missed the file → 404.

        $response->setStatusCode(404)
            ->setHeader('Content-Type', 'text/plain')
            ->setBody('404 Not Found');
    }
);

fprintf(
    STDERR,
    "[true-async-server] %d workers · :%d%s · pid %d\n",
    $workers,
    $port,
    $tlsAvailable ? " · tls :{$tlsPort}" : '',
    getmypid()
);

// HttpServer::start() spawns the pool, runs the bootloader on every
// worker, transfers $server, and awaits all workers internally.
$server->start();
