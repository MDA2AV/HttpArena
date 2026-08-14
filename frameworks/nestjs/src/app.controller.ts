import { Controller, Get, Header, Param, Post, Query, Req } from '@nestjs/common';
import { Request } from 'express';
import { readFileSync } from 'node:fs';

interface Rating {
  score: number;
  count: number;
}

interface DatasetItem {
  id: number;
  name: string;
  category: string;
  price: number;
  quantity: number;
  active: boolean;
  tags: string[];
  rating: Rating;
}

let dataset: DatasetItem[] = [];
try {
  dataset = JSON.parse(readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
} catch {
  dataset = [];
}

function sumQuery(query: Record<string, unknown>): number {
  let sum = 0;
  for (const value of Object.values(query)) {
    const n = parseInt(String(value), 10);
    if (!Number.isNaN(n)) sum += n;
  }
  return sum;
}

// The default body parsers are disabled in main.ts, so the POST endpoints read
// the raw stream: they only sum or count what arrives.
function readBody(req: Request): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (chunk: Buffer) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function countBody(req: Request): Promise<number> {
  return new Promise((resolve, reject) => {
    let size = 0;
    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
    });
    req.on('end', () => resolve(size));
    req.on('error', reject);
  });
}

@Controller()
export class AppController {
  @Get('pipeline')
  @Header('Content-Type', 'text/plain')
  pipeline(): string {
    return 'ok';
  }

  @Get('baseline11')
  @Header('Content-Type', 'text/plain')
  baselineGet(@Query() query: Record<string, unknown>): string {
    return String(sumQuery(query));
  }

  @Post('baseline11')
  @Header('Content-Type', 'text/plain')
  async baselinePost(
    @Query() query: Record<string, unknown>,
    @Req() req: Request,
  ): Promise<string> {
    let total = sumQuery(query);
    const n = parseInt((await readBody(req)).toString().trim(), 10);
    if (!Number.isNaN(n)) total += n;
    return String(total);
  }

  @Get('json/:count')
  jsonItems(@Param('count') rawCount: string, @Query('m') rawM?: string) {
    let count = parseInt(rawCount, 10) || 0;
    if (count < 0) count = 0;
    if (count > dataset.length) count = dataset.length;
    const m = parseInt(rawM ?? '1', 10) || 1;

    const items = dataset.slice(0, count).map((item) => ({
      ...item,
      total: item.price * item.quantity * m,
    }));
    return { items, count };
  }

  @Post('upload')
  @Header('Content-Type', 'text/plain')
  async upload(@Req() req: Request): Promise<string> {
    return String(await countBody(req));
  }
}
