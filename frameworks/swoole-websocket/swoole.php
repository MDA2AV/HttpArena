<?php
use Swoole\WebSocket\Server;
use Swoole\WebSocket\Frame;

$websocket = new Server('0.0.0.0', 8080);
$websocket->set([
    'worker_num'         => swoole_cpu_num(),
    'enable_reuse_port'  => true,
    'enable_coroutine'   => false,
    'package_max_length' => 30 * 1024 * 1024
]);

$websocket->on('message', function (Server $server, Frame $frame) {
    $server->push($frame->fd, $frame);
});

$websocket->start();
