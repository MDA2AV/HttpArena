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

    // ---- crud -------------------------------------------------------------
    // Same pooled PDO the async-db profile uses. Each returns the JSON body the
    // profile expects, or null where the row is missing.

    private const CRUD_COLUMNS =
        'id, name, category, price, quantity, active, tags, rating_score, rating_count';

    private static function shape(array $row): array
    {
        return [
            'id'       => (int)$row['id'],
            'name'     => $row['name'],
            'category' => $row['category'],
            'price'    => (int)$row['price'],
            'quantity' => (int)$row['quantity'],
            'active'   => (bool)$row['active'],
            // tags is a JSONB column, so PDO hands it back as text
            'tags'     => json_decode($row['tags'], true),
            'rating'   => [
                'score' => (int)$row['rating_score'],
                'count' => (int)$row['rating_count'],
            ],
        ];
    }

    public static function available(): bool
    {
        // Same lazy init as query(): the pool is opened per worker on first use,
        // so a crud request landing on a worker that has not served async-db yet
        // must open it rather than answer 500.
        if (!self::$available) {
            self::init();
        }
        return self::$available && self::$pdo !== null;
    }

    public static function crudList(string $category, int $page, int $limit): ?string
    {
        if (!self::available()) {
            return null;
        }
        try {
            $stmt = self::$pdo->prepare(
                'SELECT ' . self::CRUD_COLUMNS
                . ' FROM items WHERE category = ? ORDER BY id LIMIT ? OFFSET ?'
            );
            $stmt->execute([$category, $limit, ($page - 1) * $limit]);
            $items = [];
            while ($row = $stmt->fetch()) {
                $items[] = self::shape($row);
            }
        } catch (\Throwable $e) {
            return null;
        }
        return json_encode(
            ['items' => $items, 'total' => count($items), 'page' => $page, 'limit' => $limit],
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
        );
    }

    public static function crudCreate(array $body): ?string
    {
        if (!self::available()) {
            return null;
        }
        $name     = $body['name'] ?? 'New Product';
        $price    = $body['price'] ?? 0;
        $quantity = $body['quantity'] ?? 0;
        try {
            $stmt = self::$pdo->prepare(
                'INSERT INTO items (id, name, category, price, quantity, active, tags, '
                . 'rating_score, rating_count) '
                . 'VALUES (?, ?, ?, ?, ?, true, \'["bench"]\', 0, 0) '
                . 'ON CONFLICT (id) DO UPDATE SET name = ?, price = ?, quantity = ? RETURNING id'
            );
            $stmt->execute([
                $body['id'] ?? null, $name, $body['category'] ?? 'test', $price, $quantity,
                $name, $price, $quantity,
            ]);
            $row = $stmt->fetch();
            $stmt->closeCursor();
        } catch (\Throwable $e) {
            return null;
        }
        return json_encode([
            'id'       => (int)$row['id'],
            'name'     => $body['name'] ?? null,
            'category' => $body['category'] ?? null,
            'price'    => $body['price'] ?? null,
            'quantity' => $body['quantity'] ?? null,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    /** Returns the JSON row, false when the id is absent, null on failure. */
    public static function crudRead(int $id)
    {
        if (!self::available()) {
            return null;
        }
        try {
            $stmt = self::$pdo->prepare(
                'SELECT ' . self::CRUD_COLUMNS . ' FROM items WHERE id = ? LIMIT 1'
            );
            $stmt->execute([$id]);
            $row = $stmt->fetch();
            // Single-row fetches leave the cursor open, and a pooled PDO will
            // not hand the connection back until it is closed - a few of these
            // and every later query fails.
            $stmt->closeCursor();
        } catch (\Throwable $e) {
            return null;
        }
        if (!$row) {
            return false;
        }
        return json_encode(self::shape($row), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    /** Returns the JSON row, false when the id is absent, null on failure. */
    public static function crudUpdate(int $id, array $body)
    {
        if (!self::available()) {
            return null;
        }
        try {
            $stmt = self::$pdo->prepare(
                'UPDATE items SET name = ?, price = ?, quantity = ? WHERE id = ?'
            );
            $stmt->execute([
                $body['name'] ?? 'Updated', $body['price'] ?? 0, $body['quantity'] ?? 0, $id,
            ]);
            $affected = $stmt->rowCount();
            $stmt->closeCursor();
            if ($affected === 0) {
                return false;
            }
        } catch (\Throwable $e) {
            return null;
        }
        return json_encode([
            'id'       => $id,
            'name'     => $body['name'] ?? null,
            'price'    => $body['price'] ?? null,
            'quantity' => $body['quantity'] ?? null,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
}
