<?php

require_once __DIR__ . '/vendor/autoload.php';

$kernel = new App\Kernel('prod', false);
$kernel->boot();

$server = new \Spawn\Symfony\Server\FrankenPhpServer($kernel);
$server->start();
