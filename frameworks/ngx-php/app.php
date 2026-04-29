<?php

require 'Pgsql.php';

// Init
Pgsql::init();
define('JSON_DATA', json_decode(file_get_contents('/data/dataset.json'), true));

function baseline()
{
    $sum = array_sum(ngx::query_args());
    if(ngx_request_method() === 'POST') {
        $sum += ngx_request_body();
    }

    ngx_header_set('Content-Type', 'text/plain');
    echo $sum;
}

function json()
{
    $count = explode('/', ngx_request_document_uri())[2];
    $m = ngx_query_args()['m'] ?? 1;
    $total = [];
    $i = 0;
    while ($i < $count) {
        $item = JSON_DATA[$i++];
        $item['total'] = $item['price'] * $item['quantity'] * $m;
        $total[] = $item;
    }

    ngx_header_set('Content-Type', 'application/json');
    echo json_encode(['items' => $total, 'count' => $count],
                    JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function upload()
{
    ngx_header_set('Content-Type', 'text/plain');
    echo strlen(ngx_request_body());
}

function pipeline()
{
    ngx_header_set('Content-Type', 'text/plain');
    echo 'ok';
}

function asyncDb()
{
    ngx_header_set('Content-Type', 'application/json');
    echo Pgsql::query(
        ngx::query_args()['min'] ?? 10,
        ngx::query_args()['max'] ?? 50,
        ngx::query_args()['limit'] ?? 50
    );
}

function notFound()
{
    ngx_header_set('Content-Type', 'text/plain');
    echo 'Not Found';
    ngx_status(404);
}
