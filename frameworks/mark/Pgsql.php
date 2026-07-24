<?php

class Pgsql
{
    private static ?PDOStatement $bench;

    public static function init()
    {
        $dsn = getenv('DATABASE_URL');
        if (!$dsn) {
            return;
        }

        // Parse postgres://user:pass@host:port/dbname
        $parts = parse_url($dsn);
        $host = $parts['host'] ?? 'localhost';
        $port = $parts['port'] ?? 5432;
        $db = ltrim($parts['path'] ?? '/benchmark', '/');
        $user = $parts['user'] ?? 'bench';
        $pass = $parts['pass'] ?? 'bench';

        try {
            $pdo = new PDO(
                "pgsql:host=$host;port=$port;dbname=$db",
                $user,
                $pass,
                [
                    PDO::ATTR_DEFAULT_FETCH_MODE  => PDO::FETCH_ASSOC,
                    PDO::ATTR_ERRMODE             => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_EMULATE_PREPARES    => false
                ]
            );
            self::$bench = $pdo->prepare(
                'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT ?'
            );
        } catch (\PDOException $e) {
            self::$bench = null;
        }
    }

    public static function query($min, $max, $limit)
    {
        $result = self::$bench;
        if (!$result instanceof PDOStatement) {
            return json_encode(['items' => [], 'count' => 0],
                        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        }

        $result->execute([$min, $max, $limit]);
        $data = [];
        while ($row = $result->fetch()) {
            $data[] = [
                'id' => $row['id'],
                'name' => $row['name'],
                'category' => $row['category'],
                'price' => $row['price'],
                'quantity' => $row['quantity'],
                'active' => (bool) $row["active"],
                'tags' => json_decode($row["tags"], true),
                'rating' => [
                    "score" => $row["rating_score"],
                    "count" => $row["rating_count"]
                ],
            ];
        }
        return json_encode(['items' => $data, 'count' => count($data)],
                            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
}
