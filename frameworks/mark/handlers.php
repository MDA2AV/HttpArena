<?php

use Workerman\Protocols\Http\Response;

function pipeline()
{
    return new Response (
        200,
        ['Content-Type' => 'text/plain'],
        'ok'
    );
}

function baseline11($request)
{
    $sum = array_sum($request->get());
    if($request->method() === 'POST') {
        $sum += $request->rawBody();
    }
    
    return new Response (
        200,
        ['Content-Type' => 'text/plain'],
        $sum
    );
}

function json($request, $count)
{
    $m = $request->get('m', 1);
    $total = [];
    $i = 0;
    while ($i < $count) {
        $item = JSON_DATA[$i++];
        $item['total'] = $item['price'] * $item['quantity'] * $m;
        $total[] = $item;
    }

    return new Response (
        200,
        ['Content-Type' => 'application/json'],
        json_encode(['items' => $total, 'count' => $count], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)
    );
}

function asyncDb($request)
{
    return new Response (
        200,
        ['Content-Type' => 'application/json'],
        Pgsql::query(
            $request->get('min', 10),
            $request->get('max', 50),
            $request->get('limit', 50)
        )
    );
}

function upload($request)
{
    return new Response (
        200,
        ['Content-Type' => 'text/plain'],
        strlen($request->rawBody())
    );
}

function files($request, $path)
{
    return new Response()->withFile('/data/static/' . $path);
}
