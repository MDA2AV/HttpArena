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
use function Hyperf\Support\env;

$parts = parse_url(env('DATABASE_URL', ''));

return [
    'default' => [
        'driver' => 'pgsql',
        'host' => $parts['host'] ?? 'localhost',
        'database' => ltrim($parts['path'] ?? '/benchmark', '/'),
        'port' => intval($parts['port'] ?? 5432),
        'username' => $parts['user'] ?? 'bench',
        'password' => $parts['pass'] ?? 'bench',
        'charset' => 'utf8',
        'pool' => [
            'min_connections' => 1,
            'max_connections' => intval(env('DATABASE_MAX_CONN', 256) / swoole_cpu_num()),
            'connect_timeout' => 10.0,
            'wait_timeout' => 3.0,
            'heartbeat' => -1,
            'max_idle_time' => 60,
        ],
    ],
];
