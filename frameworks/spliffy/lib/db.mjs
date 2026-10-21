import fs from 'node:fs'
import os from 'node:os'
import pg from 'pg'

// How many workers share the Postgres budget. The same count app.mjs forks.
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

// One pool per worker, sized so that all the workers together stay under the server's
// max_connections (DATABASE_MAX_CONN, 256 by default) with a little reserve.
let pool = null
let tried = false

export function getPool () {
  if (pool || tried) return pool
  tried = true
  const url = process.env.DATABASE_URL
  if (!url) return null
  const workers = parseInt(process.env.WORKERS || '', 10) || cpuCount()
  const total = Math.min(parseInt(process.env.DATABASE_MAX_CONN || '', 10) || 256, 240)
  const perWorker = Math.max(1, Math.floor(total / workers))
  pool = new pg.Pool({ connectionString: url, max: perWorker })
  // a lost connection is retried on the next request, never a crash
  pool.on('error', () => {})
  return pool
}

// named statements are prepared once per connection and reused
export async function query (name, text, values) {
  const p = getPool()
  if (!p) return null
  try {
    return await p.query({ name, text, values })
  } catch (e) {
    tried = false
    pool = null
    throw e
  }
}
