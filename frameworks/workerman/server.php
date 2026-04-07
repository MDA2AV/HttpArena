<?php

use Workerman\Worker;
use Workerman\Protocols\Http\Response;
use Workerman\Connection\TcpConnection;
use Workerman\Protocols\Http\Http;   

require_once __DIR__ . '/vendor/autoload.php';
require_once __DIR__ . '/Db.php';
require_once __DIR__ . '/Pgsql.php';

// #### http worker ####
$http_worker = new Worker('http://0.0.0.0:8080');
$http_worker->reusePort = true;
$http_worker->count = (int) shell_exec('nproc');
$http_worker->name = 'bench';


// Increase max package size to 30MB for file upload test
TcpConnection::$defaultMaxPackageSize = 30 * 1024 * 1024;

// benchmark data
define('JSON_DATA', json_decode(file_get_contents('/data/dataset.json'), true));
define('LARGE_JSON', largeJson());

const MIME = [
    'css'   => "text/css",
    'js'    => "application/javascript",
    'html'  => "text/html",
    'woff2' => "font/woff2",
    'svg'   => "image/svg+xml",
    'webp'  => "image/webp",
    'json'  => "application/json"
    ];

define('STATIC_FILES', loadStaticFiles());

function largeJson()
{
    $data = json_decode(file_get_contents('/data/dataset-large.json'), true);
    foreach ($data as &$item) {
        $item['total'] = $item['price'] * $item['quantity'];
    }

    return json_encode(['items' => $data, 'count' => count($data)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function loadStaticFiles() 
{
    $files = [];
    $dir = new DirectoryIterator('/data/static');
    foreach ($dir as $fileinfo) {
        if (!$fileinfo->isDot()) {
            $files['/static/' . $fileinfo->getFilename()] = [
                file_get_contents($fileinfo->getPathname()),
                MIME[pathinfo($fileinfo->getFilename(), PATHINFO_EXTENSION)] ?? 'application/octet-stream'
            ];
        }
    }
    return $files;
}

$http_worker->onWorkerStart = static function () {
    Db::Init();
    Pgsql::init();
};

// Data received
$http_worker->onMessage = static function ($connection, $request) {
    $path = $request->path();
    switch ($path) {
        case '/pipeline':
            $connection->headers = ['Content-Type' => 'text/plain'];
            return $connection->send('ok');
        
        case '/baseline11':
            $sum = array_sum($request->get());
            if($request->method() === 'POST') {
                $sum += $request->rawBody();
            }
            
            $connection->headers = ['Content-Type' => 'text/plain'];
            return $connection->send($sum);

        case '/json':
            $total = [];
            foreach (JSON_DATA as $item) {
                $item['total'] = $item['price'] * $item['quantity'];
                $total[] = $item;
            }

            $connection->headers = ['Content-Type' => 'application/json'];
            return $connection->send(json_encode(['items' => $total, 'count' => count($total)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
        
        case '/upload':
            $connection->headers = ['Content-Type' => 'text/plain'];
            return $connection->send(strlen($request->rawBody()));

        case '/compression':
            if (str_contains($request->header('Accept-Encoding', ''), 'gzip')) {
                 $connection->headers = [
                    'Content-Type' => 'application/json',
                    'Content-Encoding' => 'gzip'
                ];
                return $connection->send(gzencode(LARGE_JSON, 1));
            }

            $resp = new Response(200, ['Content-Type' => 'application/json'], LARGE_JSON);
            return $connection->send($resp);

        case '/db':
            $connection->headers = ['Content-Type' => 'application/json'];
            return $connection->send(
                Db::query(
                    $request->get('min', 10),
                    $request->get('max', 50)
                )
            );

        case '/async-db':
            $connection->headers = ['Content-Type' => 'application/json'];
            return $connection->send( 
                Pgsql::query(
                    $request->get('min', 10),
                    $request->get('max', 50)
                )
            );
    }

    //Serve static files
    if (str_starts_with($path, '/static/')) {
        if (isset(STATIC_FILES[$path])) {
            $connection->headers = ['Content-Type' => STATIC_FILES[$path][1]];
            return $connection->send(STATIC_FILES[$path][0]);
        }
    }

    return $connection->send(new Response(
        404,
        ['Content-Type' => 'text/plain'],
        '404 Not Found')
    );
};

// Run all workers
Worker::runAll();
