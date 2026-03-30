<?php

class Pgsql
{
    private static PDO $pdo;
    private static PDOStatement $bench;

    public static function init()
    {
        self::$pdo = new PDO(
            'pgsql:host=localhost;port=5432;dbname=benchmark',
            'bench',
            'bench',
            [
                PDO::ATTR_DEFAULT_FETCH_MODE  => PDO::FETCH_ASSOC,
                PDO::ATTR_ERRMODE             => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_EMULATE_PREPARES    => false
            ]
        );
        self::$bench = self::$pdo->prepare(
            'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'
        );
    }

    public static function query($min, $max)
    {
        $result = self::$bench;
        $result->execute([$min, $max]);
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
                    "count" => $row["rating_count"]],
            ];
        }
        return json_encode(['items' => $data, 'count' => count($data)],
                            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
}
