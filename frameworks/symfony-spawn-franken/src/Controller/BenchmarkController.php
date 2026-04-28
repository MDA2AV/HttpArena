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
    private static array $dataset = [];
    private static array $staticFiles = [];
    private static bool $dataLoaded = false;

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
        if (self::$dataLoaded) {
            return;
        }

        self::$dataset = json_decode(file_get_contents('/data/dataset.json'), true);

        $dir = '/data/static';
        if (is_dir($dir)) {
            foreach (scandir($dir) as $file) {
                if ($file === '.' || $file === '..') continue;
                if (str_ends_with($file, '.br') || str_ends_with($file, '.gz')) continue;
                $base = $dir . '/' . $file;
                $ext  = pathinfo($file, PATHINFO_EXTENSION);
                self::$staticFiles[$file] = [
                    'data' => file_get_contents($base),
                    'mime' => self::MIME_TYPES[$ext] ?? 'application/octet-stream',
                    'br'   => file_exists($base . '.br') ? file_get_contents($base . '.br') : null,
                    'gz'   => file_exists($base . '.gz') ? file_get_contents($base . '.gz') : null,
                ];
            }
        }

        self::$dataLoaded = true;
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
        $count = max(0, min($count, count(self::$dataset)));
        $m = (int) ($request->query->get('m', 1) ?: 1);
        $items = [];
        for ($i = 0; $i < $count; $i++) {
            $item          = self::$dataset[$i];
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

    #[Route('/static/{file}', requirements: ['file' => '.+'])]
    public function static(string $file, Request $request): Response
    {
        if (!isset(self::$staticFiles[$file])) {
            return new Response('Not Found', 404, ['Content-Type' => 'text/plain']);
        }

        $f       = self::$staticFiles[$file];
        $ae      = $request->headers->get('Accept-Encoding', '');
        $headers = ['Content-Type' => $f['mime']];

        if ($f['br'] !== null && str_contains($ae, 'br')) {
            $headers['Content-Encoding'] = 'br';
            return new Response($f['br'], 200, $headers);
        }

        if ($f['gz'] !== null && str_contains($ae, 'gzip')) {
            $headers['Content-Encoding'] = 'gzip';
            return new Response($f['gz'], 200, $headers);
        }

        return new Response($f['data'], 200, $headers);
    }
}
