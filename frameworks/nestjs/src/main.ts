import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import cluster from 'node:cluster';
import { readFileSync } from 'node:fs';
import os from 'node:os';
import compression from 'compression';
import { AppModule } from './app.module';

function getCPUCount(): number {
  try {
    const max = readFileSync('/sys/fs/cgroup/cpu.max', 'utf8').trim();
    const [quota, period] = max.split(' ');
    if (quota !== 'max') {
      const cgroup = Math.floor(Number(quota) / Number(period));
      if (cgroup >= 1) return cgroup;
    }
  } catch {
    // no cgroup limit, fall back to the host CPUs
  }
  return os.availableParallelism ? os.availableParallelism() : os.cpus().length;
}

async function bootstrap() {
  // bodyParser off: the POST endpoints read the raw stream themselves.
  const app = await NestFactory.create(AppModule, { bodyParser: false, logger: false });
  app.use(compression());
  await app.listen(8080);
}

if (cluster.isPrimary) {
  const workers = getCPUCount();
  for (let i = 0; i < workers; i++) cluster.fork();
} else {
  bootstrap();
}
