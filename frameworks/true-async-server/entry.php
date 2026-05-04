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
use Async\ThreadPool;
use function Async\spawn;
use function Async\await_all_or_fail;
use function Async\available_parallelism;

require __DIR__ . '/PostgreSQL.php';

// --- Preload at process start (read once, transferred to all workers) ---

$datasetRaw   = json_decode(file_get_contents('/data/dataset.json'), true);
$datasetCount = count($datasetRaw);

$mimeTypes = [
    'css'   => 'text/css',
    'js'    => 'application/javascript',
    'html'  => 'text/html',
    'woff2' => 'font/woff2',
    'svg'   => 'image/svg+xml',
    'webp'  => 'image/webp',
    'json'  => 'application/json',
];

$staticFiles = [];
$staticDir = '/data/static';
if (is_dir($staticDir)) {
    foreach (scandir($staticDir) as $name) {
        if ($name === '.' || $name === '..') continue;
        if (str_ends_with($name, '.br') || str_ends_with($name, '.gz')) continue;
        $base = $staticDir . '/' . $name;
        $ext  = pathinfo($name, PATHINFO_EXTENSION);
        $staticFiles['/static/' . $name] = [
            'data' => file_get_contents($base),
            'mime' => $mimeTypes[$ext] ?? 'application/octet-stream',
            'br'   => file_exists($base . '.br') ? file_get_contents($base . '.br') : null,
            'gz'   => file_exists($base . '.gz') ? file_get_contents($base . '.gz') : null,
        ];
    }
}

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
    ->setReadTimeout(15)
    ->setWriteTimeout(15)
    ->setKeepAliveTimeout(60)
    ->setShutdownTimeout(5)
    ->setMaxBodySize(32 * 1024 * 1024);

if ($tlsAvailable) {
    $config
        ->addListener('0.0.0.0', $tlsPort, true)
        ->setCertificate($certPath)
        ->setPrivateKey($keyPath);
}

$server = new HttpServer($config);

$server->addHttpHandler(
    static function (HttpRequest $request, HttpResponse $response)
        use ($datasetRaw, $datasetCount, $staticFiles): void
    {
        $path = $request->getPath();

        if ($path === '/pipeline') {
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'text/plain')
                ->setBody('ok');
            return;
        }

        if ($path === '/baseline2' || $path === '/baseline11') {
            $method = $request->getMethod();
            if ($method !== 'GET' && $method !== 'POST') {
                $response->setStatusCode(405)
                    ->setHeader('Content-Type', 'text/plain')
                    ->setBody('Method Not Allowed');
                return;
            }
            $sum = 0;
            foreach ($request->getQuery() as $v) { $sum += (int)$v; }
            if ($method === 'POST') {
                $sum += (int)$request->getBody();
            }
            $response->setStatusCode(200)
                ->setHeader('Content-Type', 'text/plain')
                ->setBody((string)$sum);
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
                ->setBody((string)strlen($request->getBody()));
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

        if (str_starts_with($path, '/static/') && isset($staticFiles[$path])) {
            $f  = $staticFiles[$path];
            $ae = $request->getHeader('Accept-Encoding') ?? '';
            $response->setStatusCode(200)
                ->setHeader('Content-Type', $f['mime']);
            if ($f['br'] !== null && str_contains($ae, 'br')) {
                $response->setHeader('Content-Encoding', 'br')->setBody($f['br']);
            } elseif ($f['gz'] !== null && str_contains($ae, 'gzip')) {
                $response->setHeader('Content-Encoding', 'gzip')->setBody($f['gz']);
            } else {
                $response->setBody($f['data']);
            }
            return;
        }

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
    $futures[] = $pool->submit(static fn() => $server->start());
}

// Wait until all workers finish (i.e. until the process is stopped).
spawn(static fn() => await_all_or_fail($futures));
