<?php

use Workerman\Worker;
use Workerman\Protocols\Http\Response;
use Workerman\Connection\TcpConnection;
use Workerman\Protocols\Http\Http;   

require_once __DIR__ . '/vendor/autoload.php';
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


$http_worker->onWorkerStart = static function () {
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
        
        case '/upload':
            $connection->headers = ['Content-Type' => 'text/plain'];
            return $connection->send(strlen($request->rawBody()));

        case '/async-db':
            $connection->headers = ['Content-Type' => 'application/json'];
            return $connection->send( 
                Pgsql::query(
                    $request->get('min', 10),
                    $request->get('max', 50),
                    $request->get('limit', 50)
                )
            );
    }

    if (str_starts_with($path, '/json/')) {
        $count = explode('/', $path)[2];
        $m = $request->get('m', 1);
        $total = [];
        $i = 0;
        while ($i < $count) {
            $item = JSON_DATA[$i++];
            $item['total'] = $item['price'] * $item['quantity'] * $m;
            $total[] = $item;
        }
        $connection->headers = ['Content-Type' => 'application/json'];
        return $connection->send(json_encode(['items' => $total, 'count' => $count], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    }

    //Serve static files
    if (str_starts_with($path, '/static/')) {
        $response = (new Response())->withFile('/data' . $path);
        return $connection->send($response);
    }

    return $connection->send(new Response(
        404,
        ['Content-Type' => 'text/plain'],
        '404 Not Found')
    );
};


// #### https worker ####
// SSL context.
$context = [
    'ssl' => [
        'local_cert'  => '/certs/server.crt',
        'local_pk'    => '/certs/server.key',
        'verify_peer' => false,
    ]
];

$https = new Worker('http://0.0.0.0:8081', $context);
$https->transport = 'ssl';
$https->reusePort = true;
$https->count = (int) shell_exec('nproc');
$https->name = 'bench';



$https->onMessage = static function ($connection, $request) {

    if(str_starts_with($request->path(), '/json/')) {
        $count = explode('/', $request->path())[2];
        $m = $request->get('m', 1);
        $total = [];
        $i = 0;
        while ($i < $count) {
            $item = JSON_DATA[$i++];
            $item['total'] = $item['price'] * $item['quantity'] * $m;
            $total[] = $item;
        }
        $connection->headers = ['Content-Type' => 'application/json'];
        return $connection->send(json_encode(['items' => $total, 'count' => $count], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    }

    return $connection->send(new Response(
        404,
        ['Content-Type' => 'text/plain'],
        '404 Not Found')
    );
};

// Run all workers
Worker::runAll();
