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

    $result = json_encode(['items' => $total, 'count' => $count], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $header = [];
    if($encoding = $request->header('accept-encoding', '')) {
        if(str_contains($encoding, 'br')) {
            $result = brotli_compress($result, 1);
            $header = ['Content-Encoding' => 'br'];
        } elseif (str_contains($encoding, 'gzip')) {
            $result = gzencode($result, 1);
            $header = ['Content-Encoding' => 'br'];
        }
    }

    return new Response (
        200,
        ['Content-Type' => 'application/json'] + $header,
        $result
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
