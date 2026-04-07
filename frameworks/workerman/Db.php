<?php

class Db
{
    private static ?SQLite3Stmt $prepared;

    public static function init()
    {
        $db = new Sqlite3('/data/benchmark.db', SQLITE3_OPEN_READONLY);

        self::$prepared = $db->prepare('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
                            FROM items
                            WHERE price BETWEEN ? AND ?
                            LIMIT 50');
    }

    public static function query($min, $max)
    {
        self::$prepared->bindValue(1, $min);
        self::$prepared->bindValue(2, $max);

        $result = self::$prepared->execute();

        $data = [];
        while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
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
