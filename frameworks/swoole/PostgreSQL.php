<?php

class PostgreSQL
{
    private static ?PDOStatement $statement = null;
    private static bool $available = false;

    public static function init(): void
    {
        $parts = parse_url(getenv('DATABASE_URL'));
        $host  = $parts['host'] ?? 'localhost';
        $port  = $parts['port'] ?? 5432;
        $db    = ltrim($parts['path'] ?? '/benchmark', '/');
        $user  = $parts['user'] ?? 'bench';
        $pass  = $parts['pass'] ?? 'bench';

        $option = [
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_EMULATE_PREPARES   => false
        ];
        $pdo    = new PDO("pgsql:host=$host;port=$port;dbname=$db", $user, $pass, $option);

        self::$statement = $pdo->prepare(
            'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT ?'
        );
        self::$available = true;
    }

    public static function ensureConnected(): bool
    {
        if (self::$available) {
            return true;
        }
        self::init();
        return self::$available;
    }

    public static function query(float $min, float $max, int $limit = 50): bool|string
    {
        if (!self::ensureConnected()) {
            return '{"items":[],"count":0}';
        }
        try {
            self::$statement->execute([$min, $max, $limit]);
            $data = [];
            while ($row = self::$statement->fetch()) {
                $data[] = [
                    'id'       => $row['id'],
                    'name'     => $row['name'],
                    'category' => $row['category'],
                    'price'    => $row['price'],
                    'quantity' => $row['quantity'],
                    'active'   => (bool)$row["active"],
                    'tags'     => json_decode($row["tags"], true),
                    'rating'   => [
                        "score" => $row["rating_score"],
                        "count" => $row["rating_count"]
                    ],
                ];
            }
            return json_encode(['items' => $data, 'count' => count($data)],
                JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        } catch (\Exception $e) {
            self::$available = false;
            self::$statement = null;
            return '{"items":[],"count":0}';
        }
    }
}
