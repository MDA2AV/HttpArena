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

use Hyperf\Contract\OnCloseInterface;
use Hyperf\Contract\OnMessageInterface;
use Hyperf\Contract\OnOpenInterface;
use Hyperf\Engine\WebSocket\Frame;
use Hyperf\Engine\WebSocket\Response;

class WebSocketController implements OnMessageInterface, OnOpenInterface, OnCloseInterface
{
    public function onMessage($server, $frame): void
    {
        $response = (new Response($server))->init($frame);
        $response->push(new Frame(opcode: $frame->opcode, payloadData: $frame->data));
    }

    public function onClose($server, int $fd, int $reactorId): void
    {
    }

    public function onOpen($server, $request): void
    {
    }
}
