<?php

require __DIR__ . '/../vendor/autoload.php';

use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;

$dataset = [];
$datasetPath = getenv('DATASET_PATH') ?: '/data/dataset.json';
if (is_readable($datasetPath)) {
    $dataset = json_decode(file_get_contents($datasetPath), true) ?: [];
}

$app = AppFactory::create();

$app->get('/pipeline', function (Request $request, Response $response) {
    $response->getBody()->write('ok');
    return $response->withHeader('Content-Type', 'text/plain');
});

$baseline11 = function (Request $request, Response $response) {
    $sum = 0;
    foreach ($request->getQueryParams() as $value) {
        if (is_numeric($value)) {
            $sum += (int) $value;
        }
    }
    $body = trim((string) $request->getBody());
    if (is_numeric($body)) {
        $sum += (int) $body;
    }
    $response->getBody()->write((string) $sum);
    return $response->withHeader('Content-Type', 'text/plain');
};

$app->get('/baseline11', $baseline11);
$app->post('/baseline11', $baseline11);

$app->get('/json/{count}', function (Request $request, Response $response, array $args) use ($dataset) {
    $count = max(0, min((int) $args['count'], count($dataset)));
    $m = (int) ($request->getQueryParams()['m'] ?? 1);
    if ($m === 0) {
        $m = 1;
    }

    $items = [];
    for ($i = 0; $i < $count; $i++) {
        $item = $dataset[$i];
        $item['total'] = $item['price'] * $item['quantity'] * $m;
        $items[] = $item;
    }

    $response->getBody()->write(json_encode(['items' => $items, 'count' => $count]));
    return $response->withHeader('Content-Type', 'application/json');
});

$app->post('/upload', function (Request $request, Response $response) {
    $size = 0;
    $body = $request->getBody();
    while (!$body->eof()) {
        $size += strlen($body->read(65536));
    }
    $response->getBody()->write((string) $size);
    return $response->withHeader('Content-Type', 'text/plain');
});

$app->run();
