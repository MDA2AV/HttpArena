<?php

require __DIR__ . '/Pgsql.php';
require __DIR__ . '/data.php';

$path = $_SERVER['PATH_INFO'];

return match ($path) {
    '/baseline11' => baseline(),
    '/baseline2'  => baseline(),
    '/upload'     => upload(),
    '/pipeline'   => pipeline(),
    '/async-db'   => asyncDb(),

    default => rest($path)
};

function rest($path)
{
    return match (true) {
        str_starts_with($path, '/json/') => json($path),

        default => notFound()
    };
}

function baseline()
{
    $sum = array_sum($_GET);
    if($_SERVER['REQUEST_METHOD'] === 'POST') {
        $sum += file_get_contents('php://input');
    }

    header('Content-Type: text/plain');
    echo $sum;
}

function json($path)
{
    $count = explode('/', $path)[2];
    $m = $_GET['m'] ?? 1;
    $total = [];
    $i = 0;
    while ($i < $count) {
        $item = JSON_DATA[$i++];
        $item['total'] = $item['price'] * $item['quantity'] * $m;
        $total[] = $item;
    }
    header('Content-Type: application/json');
    echo json_encode(['items' => $total, 'count' => $count], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function upload()
{
    header('Content-Type: text/plain');
    echo $_SERVER['CONTENT_LENGTH'];
}

function pipeline()
{
    header('Content-Type: text/plain');
    echo 'ok';
}

function asyncDb()
{
    header('Content-Type: application/json');
    echo Pgsql::query(
        $_GET['min'] ?? 10,
        $_GET['max'] ?? 50,
        $_GET['limit'] ?? 50
    );
}

function notFound()
{
    header('Content-Type: text/plain', true, 404);
    echo 'Not Found';
}
