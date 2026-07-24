<?php

declare(strict_types=1);

/*
 * Native ext-sqlite3, prepare-once-per-worker. Minimal overhead path for
 * read-only SQLite — no PDO layers, no pool (sqlite is in-process, pool
 * adds no concurrency for synchronous calls and PDO core adds ~14% extra
 * instructions per request).
 */
final class SQLite
{
    private static ?\SQLite3Stmt $stmt = null;
    private static bool $available = false;

    public static function init(): void
    {
        $path = getenv('SQLITE_PATH') ?: '/data/benchmark.db';
        if (!is_readable($path)) {
            return;
        }
        $db = new \SQLite3($path, SQLITE3_OPEN_READONLY);
        self::$stmt = $db->prepare(
            'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count '
            . 'FROM items WHERE price BETWEEN ? AND ? LIMIT 50'
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

        self::$stmt->bindValue(1, $min, SQLITE3_FLOAT);
        self::$stmt->bindValue(2, $max, SQLITE3_FLOAT);
        $result = self::$stmt->execute();

        $rows = [];
        while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
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
    }
}
