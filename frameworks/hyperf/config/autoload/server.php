<?php

declare(strict_types=1);
/**
 * This file is part of Hyperf.
 *
 * @link     https://www.hyperf.io
 * @document https://hyperf.wiki
 * @contact  group@hyperf.io
 * @license  https://github.com/hyperf/hyperf/blob/master/LICENSE
 */
use Hyperf\Framework\Bootstrap\PipeMessageCallback;
use Hyperf\Framework\Bootstrap\WorkerExitCallback;
use Hyperf\Framework\Bootstrap\WorkerStartCallback;
use Hyperf\Server\Event;
use Hyperf\Server\Server;
use Swoole\Constant;

// json-tls on 8081: the same Hyperf HTTP server behind Swoole's own TLS, so
// both ports run the identical request pipeline. The harness only mounts
// /certs for the TLS profiles, so on every other profile this is an empty
// array and the listener is never opened -- Swoole aborts at startup if a
// listener names certificate files that are not there.
$jsonTlsServer = [];
if (file_exists('/certs/server.crt') && file_exists('/certs/server.key')) {
    $jsonTlsServer[] = [
        'name' => 'http-tls',
        'type' => Server::SERVER_HTTP,
        'host' => '0.0.0.0',
        'port' => 8081,
        'sock_type' => SWOOLE_SOCK_TCP | SWOOLE_SSL,
        'callbacks' => [
            Event::ON_REQUEST => [App\TlsServer::class, 'onRequest'],
        ],
        'options' => [
            'enable_request_lifecycle' => false,
        ],
        // Swoole port options live under settings; options is Hyperf's own
        'settings' => [
            'ssl_cert_file' => '/certs/server.crt',
            'ssl_key_file' => '/certs/server.key',
        ],
    ];
}

return [
    'mode' => SWOOLE_PROCESS,
    'servers' => [
        [
            'name' => 'http',
            'type' => Server::SERVER_HTTP,
            'host' => '0.0.0.0',
            'port' => 8080,
            'sock_type' => SWOOLE_SOCK_TCP,
            'callbacks' => [
                Event::ON_REQUEST => [Hyperf\HttpServer\Server::class, 'onRequest'],
            ],
            'options' => [
                // Whether to enable request lifecycle event
                'enable_request_lifecycle' => false,
            ],
        ],
        [
            'name' => 'ws',
            'type' => Server::SERVER_WEBSOCKET,
            'host' => '0.0.0.0',
            'port' => 9502,
            'sock_type' => SWOOLE_SOCK_TCP,
            'callbacks' => [
                Event::ON_HAND_SHAKE => [Hyperf\WebSocketServer\Server::class, 'onHandShake'],
                Event::ON_MESSAGE => [Hyperf\WebSocketServer\Server::class, 'onMessage'],
                Event::ON_CLOSE => [Hyperf\WebSocketServer\Server::class, 'onClose'],
            ],
        ],
        ...$jsonTlsServer,
    ],
    'settings' => [
        Constant::OPTION_ENABLE_COROUTINE => true,
        Constant::OPTION_WORKER_NUM => swoole_cpu_num(),
        Constant::OPTION_PID_FILE => BASE_PATH . '/runtime/hyperf.pid',
        Constant::OPTION_OPEN_TCP_NODELAY => true,
        Constant::OPTION_MAX_COROUTINE => 100000,
        Constant::OPTION_OPEN_HTTP2_PROTOCOL => true,
        Constant::OPTION_MAX_REQUEST => 0,
        Constant::OPTION_SOCKET_BUFFER_SIZE => 2 * 1024 * 1024,
        Constant::OPTION_BUFFER_OUTPUT_SIZE => 2 * 1024 * 1024,
        Constant::OPTION_PACKAGE_MAX_LENGTH => 30 * 1024 * 1024,
        Constant::OPTION_ENABLE_STATIC_HANDLER => true,
        Constant::OPTION_DOCUMENT_ROOT => '/data',
        Constant::OPTION_STATIC_HANDLER_LOCATIONS => ['/static'],
    ],
    'callbacks' => [
        Event::ON_WORKER_START => [WorkerStartCallback::class, 'onWorkerStart'],
        Event::ON_PIPE_MESSAGE => [PipeMessageCallback::class, 'onPipeMessage'],
        Event::ON_WORKER_EXIT => [WorkerExitCallback::class, 'onWorkerExit'],
    ],
];
