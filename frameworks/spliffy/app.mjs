// spliffy: the routes are the files under www/, this file only starts the server.
//
// One worker per usable core through node's cluster module, the standard way to run a node
// server on every core. Each worker binds the ports itself: uWebSockets.js listens with
// SO_REUSEPORT, so the kernel spreads connections over the workers and the primary is not in
// the request path. The primary only forks, and replaces a worker that dies.
import cluster from 'node:cluster'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import spliffy, { moduleDirname } from '@srfnstack/spliffy'

// the cgroup quota first, so a container with eight cores gets eight workers and not the host's count
function cpuCount () {
  try {
    const [quota, period] = fs.readFileSync('/sys/fs/cgroup/cpu.max', 'utf8').trim().split(' ')
    if (quota !== 'max') {
      const n = Math.floor(Number(quota) / Number(period))
      if (n >= 1) return n
    }
  } catch {}
  return os.availableParallelism()
}

const dir = moduleDirname(import.meta.url)

if (cluster.isPrimary) {
  const workers = parseInt(process.env.WORKERS || '', 10) || cpuCount()
  for (let i = 0; i < workers; i++) cluster.fork()
  cluster.on('exit', () => cluster.fork())
} else {
  // json-tls, static-tls and 8gbit run over TLS on 8081. The harness mounts the pair only for
  // those profiles; without it there is no TLS listener.
  const certs = process.env.CERTS_DIR || '/certs'
  const key = `${certs}/server.key`
  const cert = `${certs}/server.crt`
  const tls = fs.existsSync(key) && fs.existsSync(cert)

  spliffy({
    routeDir: path.join(dir, 'www'),
    port: 8080,
    ...(tls
      ? {
          httpsPort: 8081,
          httpsKeyFile: key,
          httpsCertFile: cert,
          // the same routes on both ports, instead of the http port redirecting to https
          httpRedirect: false
        }
      : {}),
    // Static files stay in spliffy's cache, which stats the file on every request and reads it
    // again when it changed, so a replaced file is served on the next request. Compiled
    // (declarative) static responses are read once at startup and would not follow the disk,
    // so they are off. The .br and .gz twins on disk are served by accept-encoding.
    cacheStatic: true,
    declarativeStatic: false,
    staticPrecompressed: true,
    logLevel: 'WARN'
  })
}
