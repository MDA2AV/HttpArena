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
use App\Controller\IndexController;
use App\Controller\WebSocketController;
use Hyperf\HttpServer\Router\Router;

Router::addServer('http', function () {
    Router::addRoute(['GET', 'POST'], '/baseline11', [IndexController::class, 'handleBaseline11']);
    Router::get('/pipeline', [IndexController::class, 'handlePipeline']);
    Router::get('/json/{count}', [IndexController::class, 'handleJson']);
    Router::post('/upload', [IndexController::class, 'handleUpload']);
    Router::get('/async-db', [IndexController::class, 'handleAsyncDb']);
});

Router::addServer('ws', function () {
    Router::get('/ws', WebSocketController::class);
});
