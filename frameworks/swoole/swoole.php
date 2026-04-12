<?php

use Swoole\Http\Server;
use Swoole\Http\Request;
use Swoole\Http\Response;

require __DIR__ . '/PostgreSQL.php';

$dataset = json_decode(file_get_contents('/data/dataset.json'), true);

const MIME_TYPES = [
    'css'   => "text/css",
    'js'    => "application/javascript",
    'html'  => "text/html",
    'woff2' => "font/woff2",
    'svg'   => "image/svg+xml",
    'webp'  => "image/webp",
    'json'  => "application/json"
];

$files = [];
$dir   = new DirectoryIterator('/data/static');
foreach ($dir as $fileInfo) {
    if ($fileInfo->isDot()) continue;
    $name = $fileInfo->getFilename();
    if (str_ends_with($name, '.br') || str_ends_with($name, '.gz')) continue;
    $base = $fileInfo->getPathname();
    $files['/static/' . $name] = [
        'data' => file_get_contents($base),
        'mime' => MIME_TYPES[pathinfo($name, PATHINFO_EXTENSION)] ?? 'application/octet-stream',
        'br'   => file_exists($base . '.br') ? file_get_contents($base . '.br') : null,
        'gz'   => file_exists($base . '.gz') ? file_get_contents($base . '.gz') : null,
    ];
}

$http = new Server('0.0.0.0', 8080);
$http->set([
    'worker_num'             => swoole_cpu_num(),
    'enable_reuse_port'      => true,
    'enable_coroutine'       => false,
    'package_max_length'     => 30 * 1024 * 1024,
    'http_compression_level' => 0
]);

$http->on('workerStart', function (Server $server, int $workerId) {
    PostgreSQL::init();
});

$http->on('request', function (Request $request, Response $response) use ($dataset, $files) {
    $path = $request->server['request_uri'];

    if ($path === '/pipeline') {
        $response->header['Content-Type'] = 'text/plain';
        $response->end('ok');
        return;
    }

    if ($path === '/baseline2' || $path === '/baseline11') {
        $sum = array_sum($request->get ?? []);
        if ($request->server['request_method'] === 'POST') {
            $sum += (int)$request->getContent();
        }
        $response->header['Content-Type'] = 'text/plain';
        $response->end((string)$sum);
        return;
    }

    if (preg_match('#^/json/(\d+)$#', $path, $matches)) {
        $count = min((int)$matches[1], count($dataset));
        $m = (int)($request->get['m'] ?? 1);
        if ($m === 0) $m = 1;
        $items = [];
        for ($i = 0; $i < $count; $i++) {
            $item = $dataset[$i];
            $item['total'] = $item['price'] * $item['quantity'] * $m;
            $items[] = $item;
        }
        $response->header['Content-Type'] = 'application/json';
        $response->end(json_encode(['items' => $items, 'count' => $count], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
        return;
    }

    if ($path === '/upload') {
        $response->header['Content-Type'] = 'text/plain';
        $response->end((string)strlen($request->getContent()));
        return;
    }

    if ($path === '/async-db') {
        $response->header['Content-Type'] = 'application/json';
        $min   = (int)($request->get['min'] ?? 10);
        $max   = (int)($request->get['max'] ?? 50);
        $limit = max(1, min(50, (int)($request->get['limit'] ?? 50)));
        $response->end(PostgreSQL::query($min, $max, $limit));
        return;
    }

    if (str_starts_with($path, '/static/')) {
        if (isset($files[$path])) {
            $f = $files[$path];
            $response->header['Content-Type'] = $f['mime'];
            $ae = $request->header['accept-encoding'] ?? '';
            if ($f['br'] !== null && str_contains($ae, 'br')) {
                $response->header['Content-Encoding'] = 'br';
                $response->end($f['br']);
            } elseif ($f['gz'] !== null && str_contains($ae, 'gzip')) {
                $response->header['Content-Encoding'] = 'gzip';
                $response->end($f['gz']);
            } else {
                $response->end($f['data']);
            }
            return;
        }
    }

    $response->status(404);
    $response->header['Content-Type'] = 'text/plain';
    $response->end('404 Not Found');
});

$port = $http->listen('0.0.0.0', 8443, SWOOLE_TCP | SWOOLE_SSL);
$port->set([
    'open_http2_protocol'    => true,
    'ssl_cert_file'          => '/certs/server.crt',
    'ssl_key_file'           => '/certs/server.key',
    'package_max_length'     => 30 * 1024 * 1024,
    'http_compression_level' => 0,
]);

$http->start();
