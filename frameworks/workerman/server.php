<?php

use Workerman\Worker;
use Workerman\Protocols\Http\Response;

require_once __DIR__ . '/vendor/autoload.php';
require_once __DIR__ . '/db.php';

// #### http worker ####
$http_worker = new Worker('http://0.0.0.0:8080');
$http_worker->reusePort = true;

// 1 process per CPU core
$http_worker->count = (int) shell_exec('nproc');

// benchmark data
$jsonData = json_decode(file_get_contents('/data/dataset.json'), true);

function largeJson()
{
    $data = json_decode(file_get_contents('/data/dataset-large.json'), true);
    foreach ($data as &$item) {
        $item['total'] = $item['price'] * $item['quantity'];
    }

    return json_encode(['items' => $data, 'count' => count($data)]);
}
$largeJson = largeJson();

$http_worker->onWorkerStart = static function () {
    DB::Init();
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
                $sum += (int) $request->rawBody();
            }
            
            $connection->headers = ['Content-Type' => 'text/plain'];
            return $connection->send($sum);

        case '/json':
            global $jsonData;

            $total = [];
            foreach ($jsonData as $item) {
                $item['total'] = $item['price'] * $item['quantity'];
                $total[] = $item;
            }

            $connection->headers = ['Content-Type' => 'application/json'];
            return $connection->send(json_encode(['items' => $total, 'count' => count($total)]));
        
        case '/upload':
            $connection->headers = ['Content-Type' => 'text/plain'];
            return $connection->send(strlen($request->rawBody()));

        case '/compression':
             global $largeJson;

            if ($request->header('Accept-Encoding') ?? null === 'gzip') {
                return $connection->send(new Response(
                                    200, [
                                    'Content-Type' => 'application/json',
                                    'Content-Encoding' => 'gzip'
                                    ], gzencode($largeJson, 1))
                );
            }

            $resp = new Response(200, ['Content-Type' => 'application/json'], $largeJson);
            return $connection->send($resp);

        case '/db':
            $min = (float) $request->get('min', 10);
            $max = (float) $request->get('max', 50);

            $connection->headers = ['Content-Type' => 'application/json'];
            return $connection->send(DB::query($min, $max));
    }

    // Serve static files
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

// Run all workers
Worker::runAll();
