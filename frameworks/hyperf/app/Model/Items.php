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

namespace App\Model;

use Hyperf\Database\Model\Model;

class Items extends Model
{
    protected ?string $table = 'items';

    protected array $casts = [
        'active' => 'boolean',
        'tags' => 'json',
    ];

    protected array $appends = [
        'rating',
    ];

    public function getRatingAttribute(): array
    {
        return [
            'score' => $this->attributes['rating_score'],
            'count' => $this->attributes['rating_count'],
        ];
    }
}
