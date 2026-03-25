<?php

$jsonData = json_decode(file_get_contents('/data/dataset.json'), true);

//$db = new SQLite3('/data/benchmark.db', SQLITE3_OPEN_READONLY);
// mejor un prepared statement
// $stmt = $db->prepare('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50');

// $largeJson = json_decode(file_get_contents('/data/large-dataset.json'), true);
// foreach ($largeJson as &$item) {
//     $item['total'] = $item['price'] * $item['quantity'];
// }
// $largeJson = json_encode(['items' => $largeJson, 'count' => 6000]);

//$bad = fn($x) => !in_array($x, ['POST', 'GET', 'HEAD']);

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
    global $jsonData;

    $total = [];
    foreach ($jsonData as $item) {
        $item['total'] = $item['price'] * $item['quantity'];
        $total[] = $item;
    }

    ngx_header_set('Content-Type', 'application/json');
    echo json_encode(['items' => $total, 'count' => 50]);
}

function upload()
{
    ngx_header_set('Content-Type', 'text/plain');
    echo strlen(ngx_request_body());
}

//function compression()
//{
    //global $largeJson;

//    ngx_header_set('Content-Type', 'application/json');
    //echo $largeJson;
//}

function pipeline()
{
    ngx_header_set('Content-Type', 'text/plain');
    echo 'ok';
}