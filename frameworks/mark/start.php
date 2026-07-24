<?php

use Mark\App;
use Workerman\Connection\TcpConnection;

require 'vendor/autoload.php';

// Increase max package size to 25MB for file upload test
TcpConnection::$defaultMaxPackageSize = 25 * 1024 * 1024;

// benchmark data
define('JSON_DATA', json_decode(file_get_contents('/data/dataset.json'), true));

$api = new App('http://0.0.0.0:8080');

$api->name = "Mark";
$api->reusePort = true;

$api->count = (int) shell_exec('nproc');

// $api->get('/pipeline', fn() =>
//     new Response (
//         200,
//         ['Content-Type' => 'text/plain'],
//         'ok'
//     )
// );

$api->get('/pipeline', 'pipeline');
$api->any('/baseline11', 'baseline11');
$api->get('/json/{count:\d+}', 'json');
$api->post('/upload', 'upload');
$api->get('/async-db', 'asyncDb');
$api->get('/static/{path}', 'files');

$api->onWorkerStart = static function () {
    Pgsql::init();
};

$api->start();
