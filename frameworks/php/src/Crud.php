<?php

// The crud profile: paginated list, cache-aside read, upsert, and update with
// invalidation. Shares the persistent Postgres handle with Pgsql - pg_pconnect
// hands back the same connection for the life of the fpm worker.
class Crud
{
    private const COLUMNS =
        'id, name, category, price, quantity, active, tags, rating_score, rating_count';
    private const TTL_MS = 200;

    private static function db()
    {
        return pg_pconnect('host=localhost port=5432 dbname=benchmark user=bench password=bench');
    }

    // Redis is the cache here rather than an in-process array: fpm serves each
    // request from whichever worker is free, so a per-process cache would report
    // a miss for an item another worker had already cached.
    private static function redis(): ?Redis
    {
        static $redis = null;
        static $tried = false;
        if ($tried) {
            return $redis;
        }
        $tried = true;
        $url = getenv('REDIS_URL');
        if ($url === false || $url === '') {
            return null;
        }
        $parts = parse_url($url);
        try {
            $r = new Redis();
            $r->pconnect($parts['host'] ?? '127.0.0.1', $parts['port'] ?? 6379);
            $redis = $r;
        } catch (Throwable) {
            $redis = null;
        }
        return $redis;
    }

    private static function shape(array $row): array
    {
        return [
            'id' => (int) $row['id'],
            'name' => $row['name'],
            'category' => $row['category'],
            'price' => (int) $row['price'],
            'quantity' => (int) $row['quantity'],
            'active' => (bool) $row['active'],
            'tags' => json_decode($row['tags'], true),
            'rating' => [
                'score' => (int) $row['rating_score'],
                'count' => (int) $row['rating_count'],
            ],
        ];
    }

    private static function send(array $body, int $status = 200, ?string $cache = null): void
    {
        header('Content-Type: application/json', true, $status);
        if ($cache !== null) {
            header('X-Cache: ' . $cache);
        }
        echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    public static function list(): void
    {
        $category = $_GET['category'] ?? 'electronics';
        $page = max(1, (int) ($_GET['page'] ?? 1));
        $limit = min(50, max(1, (int) ($_GET['limit'] ?? 10)));

        $result = pg_query_params(
            self::db(),
            'SELECT ' . self::COLUMNS . ' FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3',
            [$category, $limit, ($page - 1) * $limit]
        );
        $items = [];
        while ($row = pg_fetch_assoc($result)) {
            $items[] = self::shape($row);
        }
        self::send(['items' => $items, 'total' => count($items), 'page' => $page, 'limit' => $limit]);
    }

    public static function read(int $id): void
    {
        $redis = self::redis();
        if ($redis !== null) {
            $hit = $redis->get('crud:' . $id);
            if ($hit !== false) {
                header('Content-Type: application/json');
                header('X-Cache: HIT');
                echo $hit;
                return;
            }
        }
        $result = pg_query_params(
            self::db(),
            'SELECT ' . self::COLUMNS . ' FROM items WHERE id = $1 LIMIT 1',
            [$id]
        );
        $row = pg_fetch_assoc($result);
        if ($row === false) {
            header('Content-Type: text/plain', true, 404);
            echo 'Not Found';
            return;
        }
        $json = json_encode(self::shape($row), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if ($redis !== null) {
            $redis->set('crud:' . $id, $json, ['px' => self::TTL_MS]);
        }
        header('Content-Type: application/json');
        header('X-Cache: MISS');
        echo $json;
    }

    public static function create(): void
    {
        $b = json_decode(file_get_contents('php://input'), true) ?? [];
        $result = pg_query_params(
            self::db(),
            'INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) '
            . 'VALUES ($1, $2, $3, $4, $5, true, \'["bench"]\', 0, 0) '
            . 'ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id',
            [$b['id'] ?? 0, $b['name'] ?? 'New Product', $b['category'] ?? 'test',
             $b['price'] ?? 0, $b['quantity'] ?? 0]
        );
        $row = pg_fetch_assoc($result);
        self::send([
            'id' => (int) $row['id'], 'name' => $b['name'] ?? null,
            'category' => $b['category'] ?? null, 'price' => $b['price'] ?? null,
            'quantity' => $b['quantity'] ?? null,
        ], 201);
    }

    public static function update(int $id): void
    {
        $b = json_decode(file_get_contents('php://input'), true) ?? [];
        $result = pg_query_params(
            self::db(),
            'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4 RETURNING id',
            [$b['name'] ?? 'Updated', $b['price'] ?? 0, $b['quantity'] ?? 0, $id]
        );
        if (pg_fetch_assoc($result) === false) {
            header('Content-Type: text/plain', true, 404);
            echo 'Not Found';
            return;
        }
        $redis = self::redis();
        if ($redis !== null) {
            $redis->del('crud:' . $id);
        }
        self::send([
            'id' => $id, 'name' => $b['name'] ?? null,
            'price' => $b['price'] ?? null, 'quantity' => $b['quantity'] ?? null,
        ]);
    }
}
