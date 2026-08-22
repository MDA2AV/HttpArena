<?php

use Swoole\Http\Request;
use Swoole\Http\Response;
use Swoole\Table;

/**
 * crud: REST over the same Postgres the async-db profile reads, with a
 * cache-aside in front of the single-item read.
 *
 * The connection is per worker. Swoole forks one worker per core and each opens
 * its own PDO handle, so the cache cannot be a plain array: the profile reads
 * ids at random out of 50,000 and each worker would hold only its own fraction
 * of them. Swoole\Table is shared memory, allocated before the workers fork, so
 * all of them read and write the same rows - the in-process cache the profile
 * asks for by default, with no sidecar.
 */
class Crud
{
    private const COLUMNS =
        'id, name, category, price, quantity, active, tags, rating_score, rating_count';

    // The profile reads and writes the same ids, so a long TTL would answer from
    // a copy the writes have already moved past.
    private const TTL_MS = 200;

    private static ?PDO $pdo = null;
    private static ?Table $cache = null;
    private static bool $tried = false;

    /**
     * Allocate the shared table. Must run before $http->start() so the mapping
     * is inherited by every worker.
     *
     * Sized well above the id space the profile reads, which is 50,000. A
     * Swoole\Table holds fewer rows than it is declared with - the hash keeps a
     * bounded conflict pool, and a table declared 65,536 stopped accepting new
     * keys at about 34,900 and topped out near 43,400. At that point every write
     * failed and each one logged, which is how one crud run produced 66,157
     * copies of "Swoole\Table::set(): failed to set". 131,072 takes 60,000
     * distinct keys with room to spare.
     */
    public static function initCache(int $rows = 1 << 17): void
    {
        $table = new Table($rows);
        $table->column('body', Table::TYPE_STRING, 1024);
        // Table carries no TTL of its own, so the deadline rides with the row.
        $table->column('expires', Table::TYPE_INT, 8);
        $table->create();
        self::$cache = $table;
    }

    /**
     * Drop rows whose deadline has passed.
     *
     * The table cannot grow, and a row is otherwise only removed when a read
     * finds it expired - an id written once and never read again holds its slot
     * for the life of the process. Sweeping keeps a long run from filling it.
     */
    private static function sweepExpired(): void
    {
        if (self::$cache === null) {
            return;
        }
        $now = (int)(microtime(true) * 1000);
        foreach (self::$cache as $key => $row) {
            if ($row['expires'] <= $now) {
                self::$cache->del($key);
            }
        }
    }

    private static function pdo(): ?PDO
    {
        if (self::$pdo !== null || self::$tried) {
            return self::$pdo;
        }
        self::$tried = true;
        $dsn = getenv('DATABASE_URL');
        if (!$dsn) {
            return null;
        }
        $parts = parse_url($dsn);
        $host  = $parts['host'] ?? 'localhost';
        $port  = $parts['port'] ?? 5432;
        $db    = ltrim($parts['path'] ?? '/benchmark', '/');
        try {
            self::$pdo = new PDO(
                "pgsql:host=$host;port=$port;dbname=$db",
                $parts['user'] ?? 'bench',
                $parts['pass'] ?? 'bench',
                [
                    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                    PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                    PDO::ATTR_EMULATE_PREPARES   => false,
                ]
            );
        } catch (\Throwable $e) {
            self::$pdo = null;
        }
        return self::$pdo;
    }

    private static function cacheGet(string $key): ?string
    {
        if (self::$cache === null) {
            return null;
        }
        $row = self::$cache->get($key);
        if ($row === false) {
            return null;
        }
        if ($row['expires'] <= (int)(microtime(true) * 1000)) {
            self::$cache->del($key);
            return null;
        }
        return $row['body'];
    }

    private static function cacheSet(string $key, string $body): void
    {
        // A body wider than the column simply is not cached; every crud row is
        // far smaller, and a truncated one would hand back invalid JSON.
        if (self::$cache === null || strlen($body) > 1024) {
            return;
        }
        $row = [
            'body'    => $body,
            'expires' => (int)(microtime(true) * 1000) + self::TTL_MS,
        ];
        // A full table answers false and raises a warning. Sweep the expired
        // rows and try once more; if it still will not fit, the read simply
        // goes to Postgres next time, which is the same outcome as a miss and
        // costs nothing but the query.
        if (@self::$cache->set($key, $row) === false) {
            self::sweepExpired();
            @self::$cache->set($key, $row);
        }
    }

    private static function cacheDel(string $key): void
    {
        if (self::$cache !== null) {
            self::$cache->del($key);
        }
    }

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

    private static function json(Response $response, $payload, int $status = 200, array $extra = []): void
    {
        $response->status($status);
        $response->header['Content-Type'] = 'application/json';
        foreach ($extra as $k => $v) {
            $response->header[$k] = $v;
        }
        $response->end(is_string($payload) ? $payload : json_encode(
            $payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
        ));
    }

    public static function list(Request $request, Response $response): void
    {
        $pdo = self::pdo();
        if ($pdo === null) {
            self::json($response, ['error' => 'DB not available'], 500);
            return;
        }
        $category = $request->get['category'] ?? 'electronics';
        $page     = max(1, (int)($request->get['page'] ?? 1));
        $limit    = max(1, min(50, (int)($request->get['limit'] ?? 10)));
        try {
            $stmt = $pdo->prepare(
                'SELECT ' . self::COLUMNS . ' FROM items WHERE category = ? ORDER BY id LIMIT ? OFFSET ?'
            );
            $stmt->execute([$category, $limit, ($page - 1) * $limit]);
            $items = [];
            while ($row = $stmt->fetch()) {
                $items[] = self::shape($row);
            }
        } catch (\Throwable $e) {
            self::json($response, ['error' => 'query failed'], 500);
            return;
        }
        self::json($response, [
            'items' => $items, 'total' => count($items), 'page' => $page, 'limit' => $limit,
        ]);
    }

    public static function create(Request $request, Response $response): void
    {
        $pdo = self::pdo();
        if ($pdo === null) {
            self::json($response, ['error' => 'DB not available'], 500);
            return;
        }
        $body = json_decode((string)$request->getContent(), true);
        if (!is_array($body)) {
            self::json($response, ['error' => 'insert failed'], 500);
            return;
        }
        $name     = $body['name'] ?? 'New Product';
        $price    = $body['price'] ?? 0;
        $quantity = $body['quantity'] ?? 0;
        try {
            $stmt = $pdo->prepare(
                'INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) '
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
            self::json($response, ['error' => 'insert failed'], 500);
            return;
        }
        self::json($response, [
            'id'       => (int)$row['id'],
            'name'     => $body['name'] ?? null,
            'category' => $body['category'] ?? null,
            'price'    => $body['price'] ?? null,
            'quantity' => $body['quantity'] ?? null,
        ], 201);
    }

    public static function read(Request $request, Response $response, int $id): void
    {
        $pdo = self::pdo();
        if ($pdo === null) {
            self::json($response, ['error' => 'DB not available'], 500);
            return;
        }
        $key = 'crud:' . $id;
        $hit = self::cacheGet($key);
        if ($hit !== null) {
            self::json($response, $hit, 200, ['X-Cache' => 'HIT']);
            return;
        }
        try {
            $stmt = $pdo->prepare('SELECT ' . self::COLUMNS . ' FROM items WHERE id = ? LIMIT 1');
            $stmt->execute([$id]);
            $row = $stmt->fetch();
            $stmt->closeCursor();
        } catch (\Throwable $e) {
            self::json($response, ['error' => 'query failed'], 500);
            return;
        }
        if (!$row) {
            $response->status(404);
            $response->end('');
            return;
        }
        $body = json_encode(self::shape($row), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        self::cacheSet($key, $body);
        self::json($response, $body, 200, ['X-Cache' => 'MISS']);
    }

    public static function update(Request $request, Response $response, int $id): void
    {
        $pdo = self::pdo();
        if ($pdo === null) {
            self::json($response, ['error' => 'DB not available'], 500);
            return;
        }
        $body = json_decode((string)$request->getContent(), true);
        if (!is_array($body)) {
            self::json($response, ['error' => 'update failed'], 500);
            return;
        }
        try {
            $stmt = $pdo->prepare('UPDATE items SET name = ?, price = ?, quantity = ? WHERE id = ?');
            $stmt->execute([
                $body['name'] ?? 'Updated', $body['price'] ?? 0, $body['quantity'] ?? 0, $id,
            ]);
            $affected = $stmt->rowCount();
        } catch (\Throwable $e) {
            self::json($response, ['error' => 'update failed'], 500);
            return;
        }
        if ($affected === 0) {
            $response->status(404);
            $response->end('');
            return;
        }
        self::cacheDel('crud:' . $id);
        self::json($response, [
            'id'       => $id,
            'name'     => $body['name'] ?? null,
            'price'    => $body['price'] ?? null,
            'quantity' => $body['quantity'] ?? null,
        ]);
    }
}
