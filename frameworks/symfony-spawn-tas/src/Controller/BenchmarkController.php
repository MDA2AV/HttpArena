<?php

declare(strict_types=1);

namespace App\Controller;

use Doctrine\DBAL\Connection;
use Doctrine\DBAL\ParameterType;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

class BenchmarkController
{
    private array $dataset = [];
    private bool $dataLoaded = false;

    private const MIME_TYPES = [
        'css'   => 'text/css',
        'js'    => 'application/javascript',
        'html'  => 'text/html',
        'woff2' => 'font/woff2',
        'svg'   => 'image/svg+xml',
        'webp'  => 'image/webp',
        'json'  => 'application/json',
    ];

    public function __construct(private readonly Connection $connection)
    {
        if ($this->dataLoaded) {
            return;
        }

        $datasetPath = '/data/dataset.json';
        if (is_readable($datasetPath)) {
            $this->dataset = json_decode(file_get_contents($datasetPath), true) ?? [];
        }
        $this->dataLoaded = true;
    }

    #[Route('/baseline11', methods: ['GET', 'POST'])]
    #[Route('/baseline2', methods: ['GET', 'POST'])]
    public function baseline(Request $request): Response
    {
        $sum = array_sum($request->query->all());
        if ($request->isMethod('POST')) {
            $sum += (int) $request->getContent();
        }
        return new Response((string) $sum, 200, ['Content-Type' => 'text/plain']);
    }

    #[Route('/pipeline')]
    public function pipeline(): Response
    {
        return new Response('ok', 200, ['Content-Type' => 'text/plain']);
    }

    #[Route('/json/{count}', requirements: ['count' => '\d+'])]
    public function json(int $count, Request $request): Response
    {
        $count = max(0, min($count, count($this->dataset)));
        $m = (int) ($request->query->get('m', 1) ?: 1);
        $items = [];
        for ($i = 0; $i < $count; $i++) {
            $item          = $this->dataset[$i];
            $item['total'] = $item['price'] * $item['quantity'] * $m;
            $items[]       = $item;
        }
        return new Response(
            json_encode(['items' => $items, 'count' => $count], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
            200,
            ['Content-Type' => 'application/json']
        );
    }

    #[Route('/upload', methods: ['POST'])]
    public function upload(Request $request): Response
    {
        return new Response((string) strlen($request->getContent()), 200, ['Content-Type' => 'text/plain']);
    }

    #[Route('/async-db')]
    public function asyncDb(Request $request): Response
    {
        $min   = (int) ($request->query->get('min', 10));
        $max   = (int) ($request->query->get('max', 50));
        $limit = max(1, min(50, (int) ($request->query->get('limit', 50))));

        try {
            $stmt = $this->connection->prepare(
                'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT ?'
            );
            $stmt->bindValue(1, $min);
            $stmt->bindValue(2, $max);
            $stmt->bindValue(3, $limit, ParameterType::INTEGER);
            $result = $stmt->executeQuery();
            $rows   = $result->fetchAllAssociative();

            $items = array_map(static function (array $row): array {
                $row['active'] = (bool) $row['active'];
                $row['tags']   = json_decode($row['tags'], true);
                $row['rating'] = [
                    'score' => (int) $row['rating_score'],
                    'count' => (int) $row['rating_count'],
                ];
                unset($row['rating_score'], $row['rating_count']);
                return $row;
            }, $rows);

            return new Response(
                json_encode(['items' => $items, 'count' => count($items)]),
                200,
                ['Content-Type' => 'application/json']
            );
        } catch (\Throwable) {
            return new Response('{"items":[],"count":0}', 200, ['Content-Type' => 'application/json']);
        }
    }

    #[Route('/sqlite-db')]
    public function sqliteDb(Request $request): Response
    {
        $min   = (int) ($request->query->get('min', 10));
        $max   = (int) ($request->query->get('max', 50));
        $limit = max(1, min(50, (int) ($request->query->get('limit', 50))));

        $dbPath = $_ENV['SQLITE_DB_PATH'] ?? '/data/benchmark.db';

        try {
            $pdo = new \PDO('sqlite:' . $dbPath);
            $pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);

            $stmt = $pdo->prepare(
                'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN :min AND :max LIMIT :limit'
            );
            $stmt->bindValue(':min', $min, \PDO::PARAM_INT);
            $stmt->bindValue(':max', $max, \PDO::PARAM_INT);
            $stmt->bindValue(':limit', $limit, \PDO::PARAM_INT);
            $stmt->execute();

            $rows  = $stmt->fetchAll(\PDO::FETCH_ASSOC);
            $items = array_map(static function (array $row): array {
                $row['active'] = (bool) $row['active'];
                $row['tags']   = json_decode($row['tags'], true);
                $row['rating'] = [
                    'score' => (int) $row['rating_score'],
                    'count' => (int) $row['rating_count'],
                ];
                unset($row['rating_score'], $row['rating_count']);
                return $row;
            }, $rows);

            return new Response(
                json_encode(['items' => $items, 'count' => count($items)]),
                200,
                ['Content-Type' => 'application/json']
            );
        } catch (\Throwable) {
            return new Response('{"items":[],"count":0}', 200, ['Content-Type' => 'application/json']);
        }
    }

    /**
     * Fallback static file handler — only reached when TrueAsync StaticHandler
     * could not find the file (on_missing: next) or when running in dev mode.
     */
    #[Route('/static/{file}', requirements: ['file' => '.+'])]
    public function static(string $file, Request $request): Response
    {
        $dir  = '/data/static';
        $path = $dir . '/' . $file;

        if (!is_file($path) || !str_starts_with(realpath($path), realpath($dir))) {
            return new Response('Not Found', 404, ['Content-Type' => 'text/plain']);
        }

        $ext  = pathinfo($file, PATHINFO_EXTENSION);
        $mime = self::MIME_TYPES[$ext] ?? 'application/octet-stream';
        $data = file_get_contents($path);

        $headers = ['Content-Type' => $mime];
        $ae      = $request->headers->get('Accept-Encoding', '');

        $brPath = $path . '.br';
        $gzPath = $path . '.gz';

        if (file_exists($brPath) && str_contains($ae, 'br')) {
            $headers['Content-Encoding'] = 'br';
            return new Response(file_get_contents($brPath), 200, $headers);
        }

        if (file_exists($gzPath) && str_contains($ae, 'gzip')) {
            $headers['Content-Encoding'] = 'gzip';
            return new Response(file_get_contents($gzPath), 200, $headers);
        }

        return new Response($data, 200, $headers);
    }
}
