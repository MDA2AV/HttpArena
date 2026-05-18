<?php

declare(strict_types=1);

/*
 * Postgres access for TrueAsync HTTP handlers.
 *
 * Uses the native PDO connection pool shipped with ext-async (PDO::ATTR_POOL_*)
 * — each PDO method call grabs an idle connection, runs, and returns it to the
 * pool. Coroutines that find the pool exhausted park on the libuv reactor
 * instead of blocking the worker thread.
 */
final class PostgreSQL
{
    private static ?PDO $pdo = null;
    private static bool $available = false;
    private const SQL =
        'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count '
        . 'FROM items WHERE price BETWEEN ? AND ? LIMIT ?';
    private const FORTUNES_SQL = 'SELECT id, message FROM fortune';

    public static function init(): void
    {
        $url = getenv('DATABASE_URL') ?: '';
        if ($url === '') {
            return;
        }

        $parts = parse_url($url);
        $dsn   = sprintf(
            'pgsql:host=%s;port=%s;dbname=%s',
            $parts['host'] ?? 'localhost',
            $parts['port'] ?? 5432,
            ltrim($parts['path'] ?? '/benchmark', '/')
        );

        // PG sweet spot is ~4×CPU backends; more = lock/context contention.
        // Cap total at min(DATABASE_MAX_CONN, 4×CPU), split per worker.
        $cpus     = \Async\available_parallelism();
        $workers  = max(1, (int)(getenv('WORKERS') ?: $cpus));
        $envCap   = (int)(getenv('DATABASE_MAX_CONN') ?: 4 * $cpus);
        $totalMax = min($envCap, 4 * $cpus);
        $maxConn  = max(2, intdiv($totalMax, $workers));
        $minConn  = (int)(getenv('DATABASE_MIN_CONN') ?: max(1, intdiv($maxConn, 2)));

        self::$pdo = new PDO(
            $dsn,
            $parts['user'] ?? 'bench',
            $parts['pass'] ?? 'bench',
            [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES   => false,
                PDO::ATTR_POOL_ENABLED          => true,
                PDO::ATTR_POOL_MIN              => $minConn,
                PDO::ATTR_POOL_MAX              => $maxConn,
                PDO::ATTR_POOL_STMT_CACHE_SIZE  => 32,
            ]
        );

        self::$available = true;
    }

    public static function query(float $min, float $max, int $limit = 50): string
    {
        if (!self::$available) {
            self::init();
            if (!self::$available) {
                return '{"items":[],"count":0}';
            }
        }

        try {
            $stmt = self::$pdo->prepare(self::SQL);
            $stmt->execute([$min, $max, $limit]);
            $rows = [];
            while ($row = $stmt->fetch()) {
                $rows[] = [
                    'id'       => $row['id'],
                    'name'     => $row['name'],
                    'category' => $row['category'],
                    'price'    => $row['price'],
                    'quantity' => $row['quantity'],
                    'active'   => (bool)$row['active'],
                    'tags'     => json_decode($row['tags'], true),
                    'rating'   => [
                        'score' => $row['rating_score'],
                        'count' => $row['rating_count'],
                    ],
                ];
            }
            return json_encode(
                ['items' => $rows, 'count' => count($rows)],
                JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
            );
        } catch (\Throwable) {
            return '{"items":[],"count":0}';
        }
    }

    /**
     * @return list<array{id:int,message:string}>
     */
    public static function fortunes(): array
    {
        if (!self::$available) {
            self::init();
            if (!self::$available) {
                return [];
            }
        }

        try {
            $stmt = self::$pdo->prepare(self::FORTUNES_SQL);
            $stmt->execute();
            $rows = [];
            while ($row = $stmt->fetch()) {
                $rows[] = ['id' => (int)$row['id'], 'message' => (string)$row['message']];
            }
            return $rows;
        } catch (\Throwable) {
            return [];
        }
    }
}
