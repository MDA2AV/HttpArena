<?php

declare(strict_types=1);

/*
 * HttpArena entry point for the TrueAsync HTTP server.
 *
 * Architecture:
 *   - One PHP process. N worker threads (N = available_parallelism()).
 *   - Server + handler are built once in the main thread, then submitted
 *     to a ThreadPool. Each worker calls $server->start() on the same
 *     transferred object; SO_REUSEPORT lets the kernel load-balance
 *     accept()s across all threads.
 *   - Each worker has its own PDO connection pool (ext-async PDO::ATTR_POOL_*).
 *
 * Override worker count with WORKERS env var.
 */

use TrueAsync\HttpServer;
use TrueAsync\HttpServerConfig;
use TrueAsync\HttpRequest;
use TrueAsync\HttpResponse;
use TrueAsync\StaticHandler;
use Async\ThreadPool;
use function Async\spawn;
use function Async\await_all_or_fail;
use function Async\available_parallelism;

require __DIR__ . '/PostgreSQL.php';
require __DIR__ . '/SQLite.php';

// --- Preload at process start (read once, transferred to all workers) ---

$datasetRaw   = json_decode(file_get_contents('/data/dataset.json'), true);
$datasetCount = count($datasetRaw);

$staticDir = '/data/static';

// --- Runtime knobs ---

$port    = (int)(getenv('PORT') ?: 8080);
$tlsPort = (int)(getenv('TLS_PORT') ?: 8443);
$workers = (int)(getenv('WORKERS') ?: 0);
if ($workers <= 0) {
    $workers = available_parallelism();
}

$certPath     = '/certs/server.crt';
$keyPath      = '/certs/server.key';
$tlsAvailable = is_readable($certPath) && is_readable($keyPath);

// --- Step 1: build the server (one instance, transferred into each thread) ---

$config = (new HttpServerConfig())
    ->addListener('0.0.0.0', $port)
    ->setBacklog(2048)
    ->setMaxBodySize(32 * 1024 * 1024)
    // Transparent gzip/brotli middleware — needed for the json-comp profile.
    ->setCompressionEnabled(true);

if ($tlsAvailable) {
    // 8443: h2 + h1 over TLS (ALPN). 8081: h1 over TLS for the json-tls profile.
    $config
        ->addListener('0.0.0.0', $tlsPort, true)
        ->addListener('0.0.0.0', 8081, true)
        ->setCertificate($certPath)
        ->setPrivateKey($keyPath);
}

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
                $sum += (int)$request->awaitBody()->getBody();
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
                if ($mult === 0) $mult = 1;
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
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'text/plain')
                ->setBody((string)strlen($request->awaitBody()->getBody()));
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

// --- Step 2: launch pool, run $server->start() in every thread ---

fprintf(
    STDERR,
    "[true-async-server] %d workers · :%d%s · pid %d\n",
    $workers,
    $port,
    $tlsAvailable ? " · tls :{$tlsPort}" : '',
    getmypid()
);

$pool    = new ThreadPool($workers);
$futures = [];
for ($i = 0; $i < $workers; $i++) {
    // Each worker thread has its own PHP environment — re-require class files.
    $futures[] = $pool->submit(static function () use ($server): void {
        require __DIR__ . '/PostgreSQL.php';
        require __DIR__ . '/SQLite.php';
        $server->start();
    });
}

// Wait until all workers finish (i.e. until the process is stopped).
spawn(static fn() => await_all_or_fail($futures));
