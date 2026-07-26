<?php

declare(strict_types=1);
/**
 * This file is part of Hyperf.
 *
 * @link     https://www.hyperf.io
 * @document https://hyperf.wiki
 * @contact  group@hyperf.io
 * @license  https://github.com/hyperf/hyperf/blob/master/LICENSE
 */

namespace App\Controller;

use App\Model\Items;
use Hyperf\Contract\ConfigInterface;
use Hyperf\HttpServer\Contract\RequestInterface;
use Hyperf\HttpServer\Contract\ResponseInterface;
use Psr\Http\Message\ResponseInterface as PsrResponseInterface;

class IndexController
{
    protected array $dataset;

    public function __construct(protected ConfigInterface $config)
    {
        $this->dataset = $config->get('data.json');
    }

    public function handleBaseline11(RequestInterface $request, ResponseInterface $response): PsrResponseInterface
    {
        $sum = array_sum($request->query());
        if ($request->isMethod('POST')) {
            $sum += (int) $request->getBody()->getContents();
        }

        return $response->raw($sum);
    }

    public function handlePipeline(ResponseInterface $response): PsrResponseInterface
    {
        return $response->raw('ok');
    }

    public function handleJson(RequestInterface $request, ResponseInterface $response): PsrResponseInterface
    {
        $count = (int) $request->route('count');
        $m = (int) $request->query('m');

        $items = [];
        for ($i = 0; $i < $count; ++$i) {
            $item = $this->dataset[$i];
            $item['total'] = $item['price'] * $item['quantity'] * $m;
            $items[] = $item;
        }

        return $response->json([
            'items' => $items,
            'count' => $count,
        ]);
    }

    public function handleUpload(RequestInterface $request, ResponseInterface $response): PsrResponseInterface
    {
        return $response->raw($request->getBody()->getSize());
    }

    public function handleAsyncDb(RequestInterface $request, ResponseInterface $response): PsrResponseInterface
    {
        $min = (int) $request->query('min');
        $max = (int) $request->query('max');
        $limit = (int) $request->query('limit');

        $data = Items::query()->whereBetween('price', [$min, $max])->limit($limit)->get()->toArray();
        $data = array_map(function ($item) {
            unset($item['rating_score'], $item['rating_count']);
            return $item;
        }, $data);

        return $response->json([
            'items' => $data,
            'count' => count($data),
        ]);
    }
}
