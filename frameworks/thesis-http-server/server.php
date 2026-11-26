<?php

declare(strict_types=1);

use Thesis\Async\Group;
use Thesis\Http\Headers;
use Thesis\Http\Method;
use Thesis\Http\Request;
use Thesis\Http\Response;
use Thesis\Http\Server;
use Thesis\Http\Server\Config;
use Thesis\Http\Server\Gzip;
use Thesis\Http\Server\Pipeline;
use Thesis\Http\Server\Route;
use Thesis\Http\Server\Router;
use Thesis\Http\Server\StaticFiles;
use Thesis\Http\Server\TcpEndpoint;
use Thesis\Http\Status;
use Thesis\Net\Certificate;
use Thesis\Net\InetAddress;
use Thesis\Net\ServerTls;
use function Thesis\Async\awaitShutdownSignal;
use function Thesis\Async\delay;
use function Thesis\Async\group;
use function Thesis\exceptionally;
use function Thesis\Http\Server\routeParam;
use function Thesis\Time\ms;

require __DIR__ . '/vendor/autoload.php';

/** @var list<array{price: int, quantity: int, ...}> */
$dataset = json_decode(
    json: exceptionally(static fn() => file_get_contents('/data/dataset.json')),
    associative: true,
    flags: JSON_THROW_ON_ERROR,
);

$router = new Router([
    new Route([Method::GET, Method::POST], '/baseline11', static function (Request $request) {
        $a = filter_var($request->query->get('a'), FILTER_VALIDATE_INT);
        $b = filter_var($request->query->get('b'), FILTER_VALIDATE_INT);

        if ($a === false || $b === false) {
            return new Response(status: Status::BAD_REQUEST);
        }

        $sum = $a + $b;

        if ($request->method === Method::POST) {
            $c = filter_var($request->takeBody()->readAll(), FILTER_VALIDATE_INT);

            if ($c === false) {
                return new Response(status: Status::BAD_REQUEST);
            }

            $sum += $c;
        }

        return new Response(
            headers: new Headers(['Content-Type' => 'text/plain']),
            body: (string) $sum,
        );
    }),
    Route::get('/delay/{ms}', static function (Request $request) {
        $ms = filter_var(routeParam($request, 'ms'), FILTER_VALIDATE_INT);

        if ($ms === false || $ms < 0) {
            return new Response(status: Status::BAD_REQUEST);
        }

        delay(ms($ms));

        return new Response(
            headers: ['Content-Type' => 'text/plain'],
            body: (string) $ms,
        );
    }),
    Route::get('/pipeline', static fn() => new Response(
        headers: ['Content-Type' => 'text/plain'],
        body: 'ok',
    )),
    Route::get('/json/{count}', Pipeline::wrap(
        handler: static function (Request $request) use ($dataset) {
            $count = filter_var(routeParam($request, 'count'), FILTER_VALIDATE_INT);
            $multiplier = filter_var($request->query->get('m'), FILTER_VALIDATE_INT);

            if ($count === false || $count < 1 || $count > count($dataset) || $multiplier === false) {
                return new Response(status: Status::BAD_REQUEST);
            }

            $items = [];
            foreach ($dataset as $i => $item) {
                if ($i === $count) {
                    break;
                }

                $item['total'] = $item['price'] * $item['quantity'] * $multiplier;
                $items[] = $item;
            }

            return Response::json(['items' => $items, 'count' => $count]);
        },
        middleware: [new Gzip()],
    )),
    Route::post('/echo', static fn(Request $request) => new Response(
        headers: ['Content-Type' => 'application/octet-stream'],
        body: $request->takeBody(),
    )),
    new StaticFiles('/data/static')->route(prefix: '/static'),
]);

$server = new Server(
    config: new Config(endpoints: [
        new TcpEndpoint(
            address: new InetAddress('0.0.0.0', 8080),
            backlog: 4096,
            reusePort: true,
            maxConnections: 32_000,
        ),
        new TcpEndpoint(
            address: new InetAddress('0.0.0.0', 8081),
            backlog: 4096,
            reusePort: true,
            tls: new ServerTls(
                certificate: new Certificate(
                    certFile: '/certs/server.crt',
                    keyFile: '/certs/server.key',
                ),
                alpnProtocols: ['http/1.1'],
            ),
            maxConnections: 4096,
        ),
    ]),
    handler: $router,
);

group(static function (Group $group) use ($server) {
    $server->start($group);
    awaitShutdownSignal();
});
