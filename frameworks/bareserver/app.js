const cluster = require('cluster');
const os = require('os');
const fs = require('fs');

function getCPUCount() {
  for (const p of ['/sys/fs/cgroup/cpuset.cpus', '/sys/fs/cgroup/cpuset/cpuset.cpus']) {
    try {
      const cpuset = fs.readFileSync(p, 'utf8').trim();
      if (cpuset) {
        let count = 0;
        for (const part of cpuset.split(',')) {
          const [start, end] = part.split('-').map(Number);
          count += end !== undefined ? (end - start + 1) : 1;
        }
        if (count >= 1) return count;
      }
    } catch {}
  }
  try {
    const max = fs.readFileSync('/sys/fs/cgroup/cpu.max', 'utf8').trim();
    const [quota, period] = max.split(' ');
    if (quota !== 'max') {
      const cgroup = Math.floor(Number(quota) / Number(period));
      if (cgroup >= 1) return cgroup;
    }
  } catch {}
  return os.availableParallelism ? os.availableParallelism() : os.cpus().length;
}

if (cluster.isPrimary) {
  const numCPUs = getCPUCount();
  for (let i = 0; i < numCPUs; i++) cluster.fork();
  cluster.on('exit', () => cluster.fork());
} else {
  const express = require('bareserver');
  const zlib = require('zlib');
  const GZIP_OPTS = { level: 1 };
  const BROTLI_OPTS = { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 } };

  const app = express({ port: 8080 });

  // Dataset
  let datasetItems;
  try {
    datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
  } catch (e) {}

  // SQLite
  let dbStmt;
  try {
    if (fs.existsSync('/data/benchmark.db')) {
      const Database = require('better-sqlite3');
      const db = new Database('/data/benchmark.db', { readonly: true });
      db.pragma('mmap_size=268435456');
      dbStmt = db.prepare('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50');
    }
  } catch (e) {}

  // PostgreSQL with per-worker connection budget (pg.native preferred)
  let pgPool;
  const dbUrl = process.env.DATABASE_URL;
  if (dbUrl) {
    try {
      const pg = require('pg');
      const PoolClass = pg.native ? pg.native.Pool : pg.Pool;
      pgPool = new PoolClass({ connectionString: dbUrl, max: 4 });
      pgPool.on('error', () => {});
    } catch (e) {}
  }

  function parseFastInt(str, start, end) {
    let res = 0;
    let sign = 1;
    let i = start;
    if (i < end && str.charCodeAt(i) === 45) {
      sign = -1;
      i++;
    }
    let hasDigit = false;
    for (; i < end; i++) {
      const code = str.charCodeAt(i) - 48;
      if (code >= 0 && code <= 9) {
        res = res * 10 + code;
        hasDigit = true;
      } else {
        break;
      }
    }
    return hasDigit ? res * sign : NaN;
  }

  function sumQueryFast(rawQuery, queryObj) {
    if (rawQuery) {
      let sum = 0;
      let start = 0;
      const len = rawQuery.length;
      while (start < len) {
        let eq = rawQuery.indexOf('=', start);
        if (eq === -1) break;
        let amp = rawQuery.indexOf('&', eq);
        if (amp === -1) amp = len;
        const n = parseFastInt(rawQuery, eq + 1, amp);
        if (n === n) sum += n;
        start = amp + 1;
      }
      return sum;
    }
    let sum = 0;
    for (const k in queryObj) {
      const n = parseInt(queryObj[k], 10);
      if (n === n) sum += n;
    }
    return sum;
  }

  const SERVER_HDR = { server: 'bareserver' };

  // Native Rust static bypass for maximum pipelining throughput
  app.static('/pipeline', 'ok', SERVER_HDR);

  app.get('/delay/:ms', (req, res) => {
    const ms = parseInt(req.params.ms, 10);
    if (!Number.isInteger(ms) || ms < 0) return res.status(404).send();
    if (ms === 0) return res.set(SERVER_HDR).type('text/plain').send('0');
    setTimeout(() => res.set(SERVER_HDR).type('text/plain').send(String(ms)), ms);
  });

  app.get('/baseline2', (req, res) => {
    res.set(SERVER_HDR).type('text/plain').send(String(sumQueryFast(req._raw.query, req.query)));
  });

  app.get('/baseline11', (req, res) => {
    res.set(SERVER_HDR).type('text/plain').send(String(sumQueryFast(req._raw.query, req.query)));
  });

  app.post('/baseline11', (req, res) => {
    const querySum = sumQueryFast(req._raw.query, req.query);
    if (req._rawBody && req._rawBody.length > 0) {
      const n = parseInt(req._rawBody.toString('utf8').trim(), 10);
      const total = n === n ? querySum + n : querySum;
      res.set(SERVER_HDR).type('text/plain').send(String(total));
    } else {
      res.set(SERVER_HDR).type('text/plain').send(String(querySum));
    }
  });

  app.get('/json/:count', (req, res) => {
    if (!datasetItems) {
      return res.status(500).type('text/plain').send('No dataset');
    }
    let count = parseInt(req.params.count, 10) || 0;
    if (count < 0) count = 0;
    if (count > datasetItems.length) count = datasetItems.length;
    const m = parseInt(req.query.m, 10) || 1;
    const items = new Array(count);
    for (let i = 0; i < count; i++) {
      const d = datasetItems[i];
      items[i] = {
        id: d.id,
        name: d.name,
        category: d.category,
        price: d.price,
        quantity: d.quantity,
        active: d.active,
        tags: d.tags,
        rating: d.rating,
        total: d.price * d.quantity * m,
      };
    }
    const body = JSON.stringify({ items, count });
    const ae = req.get('accept-encoding') || '';
    if (ae.includes('br')) {
      res.set(SERVER_HDR).set('content-encoding', 'br').type('application/json').send(zlib.brotliCompressSync(body, BROTLI_OPTS));
    } else if (ae.includes('gzip')) {
      res.set(SERVER_HDR).set('content-encoding', 'gzip').type('application/json').send(zlib.gzipSync(body, GZIP_OPTS));
    } else {
      res.set(SERVER_HDR).type('application/json').send(body);
    }
  });

  app.get('/db', (req, res) => {
    if (!dbStmt) {
      return res.set(SERVER_HDR).json({ items: [], count: 0 });
    }
    const min = parseFloat(req.query.min) || 10;
    const max = parseFloat(req.query.max) || 50;
    const rows = dbStmt.all(min, max);
    const count = rows.length;
    const items = new Array(count);
    for (let i = 0; i < count; i++) {
      const r = rows[i];
      items[i] = {
        id: r.id,
        name: r.name,
        category: r.category,
        price: r.price,
        quantity: r.quantity,
        active: r.active === 1,
        tags: JSON.parse(r.tags),
        rating: { score: r.rating_score, count: r.rating_count },
      };
    }
    res.set(SERVER_HDR).json({ items, count });
  });

  const ASYNC_DB_QUERY = {
    name: 'async-db',
    text: 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
  };

  app.get('/async-db', (req, res) => {
    if (!pgPool) {
      return res.set(SERVER_HDR).json({ items: [], count: 0 });
    }
    const min = parseInt(req.query.min, 10) || 10;
    const max = parseInt(req.query.max, 10) || 50;
    let limit = parseInt(req.query.limit, 10) || 50;
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;
    pgPool.query({ ...ASYNC_DB_QUERY, values: [min, max, limit] }, (err, result) => {
      if (err || !result) {
        return res.set(SERVER_HDR).json({ items: [], count: 0 });
      }
      const rows = result.rows;
      const count = rows.length;
      const items = new Array(count);
      for (let i = 0; i < count; i++) {
        const r = rows[i];
        items[i] = {
          id: r.id,
          name: r.name,
          category: r.category,
          price: r.price,
          quantity: r.quantity,
          active: r.active,
          tags: r.tags,
          rating: { score: r.rating_score, count: r.rating_count },
        };
      }
      res.set(SERVER_HDR).json({ items, count });
    });
  });

  app.post('/echo', (req, res) => {
    res.set(SERVER_HDR).type('application/octet-stream').send(req._rawBody || Buffer.alloc(0));
  });

  const port = process.env.PORT ? parseInt(process.env.PORT, 10) : 8080;
  app.listen(port, () => {
    console.log(`BareServer worker ${process.pid} listening on ${port}`);
  });
}
