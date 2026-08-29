<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

$dataset = json_decode(file_get_contents(env('DATASET_PATH', '/data/dataset.json')), true) ?: [];

Route::get('/pipeline', function () {
    return response('ok')->header('Content-Type', 'text/plain');
});

Route::match(['get', 'post'], '/baseline11', function (Request $request) {
    $total = 0;
    foreach ($request->query() as $value) {
        if (is_numeric($value)) {
            $total += (int) $value;
        }
    }
    if ($request->isMethod('post')) {
        $body = trim($request->getContent());
        if (is_numeric($body)) {
            $total += (int) $body;
        }
    }

    return response((string) $total)->header('Content-Type', 'text/plain');
});

Route::get('/json/{count}', function (Request $request, int $count) use ($dataset) {
    $count = max(0, min($count, count($dataset)));
    $m = (int) $request->query('m', 1) ?: 1;

    $items = [];
    foreach (array_slice($dataset, 0, $count) as $item) {
        $item['total'] = $item['price'] * $item['quantity'] * $m;
        $items[] = $item;
    }

    return response()->json(['items' => $items, 'count' => count($items)]);
});

Route::post('/echo', function (Request $request) {
    return response($request->getContent())->header('Content-Type', 'application/octet-stream');
});
