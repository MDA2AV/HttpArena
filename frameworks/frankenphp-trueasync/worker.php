<?php

declare(strict_types=1);

use FrankenPHP\HttpServer;
use FrankenPHP\Request;
use FrankenPHP\Response;

set_time_limit(0);

// --- Preload datasets at startup ---

$dataset = json_decode(file_get_contents('/data/dataset.json'), true);
// Dataset items loaded (total computed per-request with m param)

// Preload static files into memory
$staticFiles = [];
$staticDir = '/data/static';
$mimeTypes = [
    'css'   => 'text/css',
    'js'    => 'application/javascript',
    'html'  => 'text/html',
    'woff2' => 'font/woff2',
    'svg'   => 'image/svg+xml',
    'webp'  => 'image/webp',
    'json'  => 'application/json',
];

if (is_dir($staticDir)) {
    foreach (scandir($staticDir) as $file) {
        if ($file === '.' || $file === '..') continue;
        if (str_ends_with($file, '.br') || str_ends_with($file, '.gz')) continue;
        $ext = pathinfo($file, PATHINFO_EXTENSION);
        $base = $staticDir . '/' . $file;
        $staticFiles[$file] = [
            'data' => file_get_contents($base),
            'mime' => $mimeTypes[$ext] ?? 'application/octet-stream',
            'br'   => file_exists($base . '.br') ? file_get_contents($base . '.br') : null,
            'gz'   => file_exists($base . '.gz') ? file_get_contents($base . '.gz') : null,
        ];
    }
}

// --- Database connections (lazy) ---

$sqliteDb = null;

function sqliteDb(): PDO
{
    global $sqliteDb;
    if ($sqliteDb === null) {
        $sqliteDb = new PDO('sqlite:/data/benchmark.db', null, null, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        $sqliteDb->exec('PRAGMA synchronous=OFF');
        $sqliteDb->exec('PRAGMA mmap_size=268435456');
        $sqliteDb->exec('PRAGMA cache_size=-65536');
    }
    return $sqliteDb;
}

$pgDb = null;

function pgDb(): PDO
{
    global $pgDb;
    if ($pgDb === null) {
        $url = getenv('DATABASE_URL') ?: 'postgres://bench:bench@localhost:5432/benchmark';
        $parts = parse_url($url);
        $dsn = sprintf(
            'pgsql:host=%s;port=%s;dbname=%s',
            $parts['host'],
            $parts['port'] ?? 5432,
            ltrim($parts['path'] ?? '/benchmark', '/')
        );
        $maxConn = (int)(getenv('DATABASE_MAX_CONN') ?: 512);
        $pgDb = new PDO($dsn, $parts['user'] ?? 'bench', $parts['pass'] ?? 'bench', [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
            PDO::ATTR_POOL_ENABLED       => true,
            PDO::ATTR_POOL_MIN           => 64,
            PDO::ATTR_POOL_MAX           => $maxConn,
        ]);
    }
    return $pgDb;
}

// --- Helpers ---

function textResponse(Response $response, string $body): void
{
    $response->setStatus(200);
    $response->setHeader('Content-Type', 'text/plain');
    $response->write($body);
    $response->end();
}

function jsonResponseRaw(Response $response, string $json): void
{
    $response->setStatus(200);
    $response->setHeader('Content-Type', 'application/json');
    $response->write($json);
    $response->end();
}

function parseQueryParams(string $uri): array
{
    $query = parse_url($uri, PHP_URL_QUERY) ?? '';
    parse_str($query, $params);
    return $params;
}

function transformDbRow(array $row): array
{
    $row['active'] = (bool)$row['active'];
    $row['tags'] = json_decode($row['tags'], true);
    $row['rating'] = [
        'score' => (int)$row['rating_score'],
        'count' => (int)$row['rating_count'],
    ];
    unset($row['rating_score'], $row['rating_count']);
    return $row;
}

function dbQuery(PDO $pdo, int $min, int $max, int $limit = 50): string
{
    $stmt = $pdo->prepare('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT ?');
    $stmt->execute([$min, $max, $limit]);
    $rows = $stmt->fetchAll();
    $items = array_map('transformDbRow', $rows);
    return json_encode(['items' => $items, 'count' => count($items)]);
}

// --- Handlers ---

function handleBaseline(Request $request, Response $response): void
{
    $method = $request->getMethod();

    if ($method !== 'GET' && $method !== 'POST') {
        $response->setStatus(405);
        $response->setHeader('Content-Type', 'text/plain');
        $response->write('Method Not Allowed');
        $response->end();
        return;
    }

    $params = parseQueryParams($request->getUri());
    $a = (int)($params['a'] ?? 0);
    $b = (int)($params['b'] ?? 0);
    $sum = $a + $b;

    if ($method === 'POST') {
        $body = $request->getBody();
        $sum += (int)$body;
    }

    textResponse($response, (string)$sum);
}

function handlePipeline(Response $response): void
{
    textResponse($response, 'ok');
}

function handleJson(int $count, Request $request, Response $response): void
{
    global $dataset;
    $count = max(0, min($count, count($dataset)));
    $params = parseQueryParams($request->getUri());
    $m = (int)($params['m'] ?? 1);
    if ($m === 0) $m = 1;
    $items = [];
    for ($i = 0; $i < $count; $i++) {
        $item = $dataset[$i];
        $item['total'] = $item['price'] * $item['quantity'] * $m;
        $items[] = $item;
    }
    jsonResponseRaw($response, json_encode(['items' => $items, 'count' => $count]));
}

function handleUpload(Request $request, Response $response): void
{
    $body = $request->getBody();
    textResponse($response, (string)strlen($body));
}

function handleStatic(string $path, Request $request, Response $response): void
{
    global $staticFiles;

    $file = basename($path);

    if (!isset($staticFiles[$file])) {
        $response->setStatus(404);
        $response->setHeader('Content-Type', 'text/plain');
        $response->write('Not Found');
        $response->end();
        return;
    }

    $f = $staticFiles[$file];
    $response->setStatus(200);
    $response->setHeader('Content-Type', $f['mime']);

    $ae = $request->getHeader('Accept-Encoding') ?? '';
    if ($f['br'] !== null && str_contains($ae, 'br')) {
        $response->setHeader('Content-Encoding', 'br');
        $response->write($f['br']);
    } elseif ($f['gz'] !== null && str_contains($ae, 'gzip')) {
        $response->setHeader('Content-Encoding', 'gzip');
        $response->write($f['gz']);
    } else {
        $response->write($f['data']);
    }
    $response->end();
}

function handleSyncDb(Request $request, Response $response): void
{
    $params = parseQueryParams($request->getUri());
    $min = (int)($params['min'] ?? 10);
    $max = (int)($params['max'] ?? 50);
    jsonResponseRaw($response, dbQuery(sqliteDb(), $min, $max));
}

function handleAsyncDb(Request $request, Response $response): void
{
    $params = parseQueryParams($request->getUri());
    $min = (int)($params['min'] ?? 10);
    $max = (int)($params['max'] ?? 50);
    $limit = max(1, min((int)($params['limit'] ?? 50), 50));

    try {
        jsonResponseRaw($response, dbQuery(pgDb(), $min, $max, $limit));
    } catch (\Throwable $e) {
        jsonResponseRaw($response, '{"items":[],"count":0}');
    }
}

// --- Main request router ---

HttpServer::onRequest(function (Request $request, Response $response): void {
    $uri  = $request->getUri();
    $path = parse_url($uri, PHP_URL_PATH) ?? '/';

    match (true) {
        $path === '/baseline11'   => handleBaseline($request, $response),
        $path === '/baseline2'    => handleBaseline($request, $response),
        $path === '/pipeline'     => handlePipeline($response),
        preg_match('#^/json/(\d+)$#', $path, $m) === 1 => handleJson((int)$m[1], $request, $response),
        $path === '/upload'       => handleUpload($request, $response),
        $path === '/db'           => handleSyncDb($request, $response),
        $path === '/async-db'     => handleAsyncDb($request, $response),
        str_starts_with($path, '/static/') => handleStatic($path, $request, $response),
        default => (function () use ($response) {
            $response->setStatus(404);
            $response->setHeader('Content-Type', 'text/plain');
            $response->write('Not Found');
            $response->end();
        })(),
    };
});
