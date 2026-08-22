<?php

declare(strict_types=1);

require __DIR__ . '/SharedCache.php';

use FrankenPHP\HttpServer;
use FrankenPHP\Request;
use FrankenPHP\Response;

set_time_limit(0);

// --- Preload datasets at startup ---

$dataset = json_decode(file_get_contents('/data/dataset.json'), true);
// Dataset items loaded (total computed per-request with m param)

// Static files: only paths and MIME types are resolved at startup. Bodies are
// read from disk on every request - the static profiles forbid holding them in
// memory, in every mode.
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
            'path' => $base,
            'mime' => $mimeTypes[$ext] ?? 'application/octet-stream',
            'br'   => file_exists($base . '.br') ? $base . '.br' : null,
            'gz'   => file_exists($base . '.gz') ? $base . '.gz' : null,
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
        // The pool was capped at DATABASE_MAX_CONN exactly, which is also the
        // Postgres max_connections - and some of those are reserved for the
        // superuser, so a full pool overshot and the server answered "sorry,
        // too many clients already". Leave headroom.
        $budget  = (int)(getenv('DATABASE_MAX_CONN') ?: 256);
        $maxConn = max(8, $budget - 8);
        $pgDb = new PDO($dsn, $parts['user'] ?? 'bench', $parts['pass'] ?? 'bench', [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
            PDO::ATTR_POOL_ENABLED       => true,
            PDO::ATTR_POOL_MIN           => min(16, $maxConn),
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
        $response->write(file_get_contents($f['br']));
    } elseif ($f['gz'] !== null && str_contains($ae, 'gzip')) {
        $response->setHeader('Content-Encoding', 'gzip');
        $response->write(file_get_contents($f['gz']));
    } else {
        $response->write(file_get_contents($f['path']));
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


// --- crud ------------------------------------------------------------------
// Same pooled PDO async-db uses. The cache-aside in front of the single-item
// read is SharedCache: frankenphp runs a worker per process, so a per-worker
// array would hold only its own fraction of the 50,000 ids the profile reads.

const CRUD_COLUMNS =
    'id, name, category, price, quantity, active, tags, rating_score, rating_count';

// The profile reads and writes the same ids, so a long TTL would answer from a
// copy the writes have already moved past.
const CRUD_TTL_MS = 200;

function crudShape(array $row): array
{
    return [
        'id'       => (int)$row['id'],
        'name'     => $row['name'],
        'category' => $row['category'],
        'price'    => (int)$row['price'],
        'quantity' => (int)$row['quantity'],
        'active'   => (bool)$row['active'],
        // tags is a JSONB column, so PDO hands it back as text
        'tags'     => json_decode($row['tags'], true),
        'rating'   => [
            'score' => (int)$row['rating_score'],
            'count' => (int)$row['rating_count'],
        ],
    ];
}

function crudJson(Response $response, string $body, int $status = 200, array $extra = []): void
{
    $response->setStatus($status);
    $response->setHeader('Content-Type', 'application/json');
    foreach ($extra as $k => $v) {
        $response->setHeader($k, $v);
    }
    $response->write($body);
    $response->end();
}

function handleCrudCollection(Request $request, Response $response): void
{
    if (strtoupper($request->getMethod()) === 'POST') {
        $body = json_decode((string)$request->getBody(), true);
        if (!is_array($body)) {
            crudJson($response, '{"error":"insert failed"}', 500);
            return;
        }
        $name     = $body['name'] ?? 'New Product';
        $price    = $body['price'] ?? 0;
        $quantity = $body['quantity'] ?? 0;
        try {
            $stmt = pgDb()->prepare(
                'INSERT INTO items (id, name, category, price, quantity, active, tags, '
                . 'rating_score, rating_count) '
                . "VALUES (?, ?, ?, ?, ?, true, '[\"bench\"]', 0, 0) "
                . 'ON CONFLICT (id) DO UPDATE SET name = ?, price = ?, quantity = ? RETURNING id'
            );
            $stmt->execute([
                $body['id'] ?? null, $name, $body['category'] ?? 'test', $price, $quantity,
                $name, $price, $quantity,
            ]);
            $row = $stmt->fetch();
            // Single-row fetches leave the cursor open, and a pooled PDO will not
            // hand the connection back until it is closed - a few of these and
            // every later query fails.
            $stmt->closeCursor();
        } catch (\Throwable $e) {
            crudJson($response, '{"error":"insert failed"}', 500);
            return;
        }
        crudJson($response, json_encode([
            'id'       => (int)$row['id'],
            'name'     => $body['name'] ?? null,
            'category' => $body['category'] ?? null,
            'price'    => $body['price'] ?? null,
            'quantity' => $body['quantity'] ?? null,
        ]), 201);
        return;
    }

    $params   = parseQueryParams($request->getUri());
    $category = $params['category'] ?? 'electronics';
    $page     = max(1, (int)($params['page'] ?? 1));
    $limit    = max(1, min(50, (int)($params['limit'] ?? 10)));
    try {
        $stmt = pgDb()->prepare(
            'SELECT ' . CRUD_COLUMNS . ' FROM items WHERE category = ? ORDER BY id LIMIT ? OFFSET ?'
        );
        $stmt->execute([$category, $limit, ($page - 1) * $limit]);
        $items = [];
        while ($row = $stmt->fetch()) {
            $items[] = crudShape($row);
        }
    } catch (\Throwable $e) {
        crudJson($response, '{"error":"query failed"}', 500);
        return;
    }
    crudJson($response, json_encode([
        'items' => $items, 'total' => count($items), 'page' => $page, 'limit' => $limit,
    ]));
}

function handleCrudItem(int $id, Request $request, Response $response): void
{
    $key = 'crud:' . $id;

    if (strtoupper($request->getMethod()) === 'PUT') {
        $body = json_decode((string)$request->getBody(), true);
        if (!is_array($body)) {
            crudJson($response, '{"error":"update failed"}', 500);
            return;
        }
        try {
            $stmt = pgDb()->prepare('UPDATE items SET name = ?, price = ?, quantity = ? WHERE id = ?');
            $stmt->execute([
                $body['name'] ?? 'Updated', $body['price'] ?? 0, $body['quantity'] ?? 0, $id,
            ]);
            $affected = $stmt->rowCount();
            $stmt->closeCursor();
        } catch (\Throwable $e) {
            crudJson($response, '{"error":"update failed"}', 500);
            return;
        }
        if ($affected === 0) {
            $response->setStatus(404);
            $response->end();
            return;
        }
        SharedCache::del($key);
        crudJson($response, json_encode([
            'id'       => $id,
            'name'     => $body['name'] ?? null,
            'price'    => $body['price'] ?? null,
            'quantity' => $body['quantity'] ?? null,
        ]));
        return;
    }

    $hit = SharedCache::get($key);
    if ($hit !== null) {
        crudJson($response, $hit, 200, ['X-Cache' => 'HIT']);
        return;
    }
    try {
        $stmt = pgDb()->prepare('SELECT ' . CRUD_COLUMNS . ' FROM items WHERE id = ? LIMIT 1');
        $stmt->execute([$id]);
        $row = $stmt->fetch();
        $stmt->closeCursor();
    } catch (\Throwable $e) {
        crudJson($response, '{"error":"query failed"}', 500);
        return;
    }
    if (!$row) {
        $response->setStatus(404);
        $response->end();
        return;
    }
    $body = json_encode(crudShape($row));
    SharedCache::setPx($key, $body, CRUD_TTL_MS);
    crudJson($response, $body, 200, ['X-Cache' => 'MISS']);
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
        $path === '/crud/items'   => handleCrudCollection($request, $response),
        preg_match('#^/crud/items/(\d+)$#', $path, $c) === 1
            => handleCrudItem((int)$c[1], $request, $response),
        default => (function () use ($response) {
            $response->setStatus(404);
            $response->setHeader('Content-Type', 'text/plain');
            $response->write('Not Found');
            $response->end();
        })(),
    };
});
