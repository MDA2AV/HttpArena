import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import cluster from 'node:cluster';
import { existsSync, readFileSync } from 'node:fs';
import { createServer as createHttpsServer } from 'node:https';
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

  // json-tls on 8081. The adapter's instance is the very Express app Nest just
  // wired the controllers and compression onto, so putting it behind node:https
  // serves the same pipeline rather than a second copy. Certs are only mounted
  // for the TLS profiles, hence the guard.
  const cert = '/certs/server.crt';
  const key = '/certs/server.key';
  if (existsSync(cert) && existsSync(key)) {
    createHttpsServer(
      { key: readFileSync(key), cert: readFileSync(cert) },
      app.getHttpAdapter().getInstance(),
    ).listen(8081);
  }
}

if (cluster.isPrimary) {
  const workers = getCPUCount();
  for (let i = 0; i < workers; i++) cluster.fork();
} else {
  bootstrap();
}
