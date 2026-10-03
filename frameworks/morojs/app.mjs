// morojs - MoroJS on its native HTTP engine (@morojs/engine), default
// configuration. Clustering is the framework's own: performance.clustering
// starts one worker per core, and on the native engine those are worker
// threads that each bind the port through SO_REUSEPORT. Moro re-runs this
// file in every worker; the primary only starts and supervises them.

import { spawn } from 'node:child_process';
import cluster from 'node:cluster';
import { existsSync, readFileSync } from 'node:fs';
import { availableParallelism } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMainThread } from 'node:worker_threads';
import { createApp, middleware, MemoryCacheAdapter, RedisCacheAdapter } from '@morojs/moro';
import ejs from 'ejs';
import pg from 'pg';

const HERE = dirname(fileURLToPath(import.meta.url));
const FORTUNES_VIEW = join(HERE, 'views', 'fortunes.ejs');
const DATASET_PATH = process.env.DATASET_PATH || '/data/dataset.json';
const STATIC_ROOT = '/data/static';

// One process per listener, because Moro locks one configuration per
// process. 'plain' serves :8080; 'tls' serves json-tls, static-tls and 8gbit
// on :8081 from /certs; 'tlscheck' serves the opt-in TLS hardening section on
// :9000 from /certs-tls, reloading the pair whenever the files change.
const ROLE = process.env.MORO_ROLE || 'plain';
const LISTENERS = {
    plain: { port: 8080 },
    tls: { port: 8081, certs: '/certs' },
    tlscheck: { port: 9000, certs: '/certs-tls', watch: true },
};
const pairIn = dir => ({ keyFile: join(dir, 'server.key'), certFile: join(dir, 'server.crt') });
const hasPair = dir => existsSync(pairIn(dir).keyFile) && existsSync(pairIn(dir).certFile);

// The container is pinned to a cpuset, so the cgroup quota is read first and
// availableParallelism(), which honours the affinity mask, is the fallback.
// Moro's 'auto' counts the same way now; the number is computed here as well
// because the Postgres pool below has to divide by it.
function cpuCount() {
    try {
        const [quota, period] = readFileSync('/sys/fs/cgroup/cpu.max', 'utf8').trim().split(' ');
        if (quota !== 'max') {
            const n = Math.floor(Number(quota) / Number(period));
            if (n >= 1) return n;
        }
    } catch {}
    return availableParallelism();
}
const workers = cpuCount();

// A worker thread on the native engine, a node:cluster process on the
// fallback transport. The primary serves nothing, so it loads no dataset and
// opens no database pool.
const isWorker = !isMainThread || cluster.isWorker;
const isPrimary = !isWorker;

// The harness mounts /certs for the TLS profiles and /certs-tls for the
// tls_check section only; a listener whose pair is absent is not started.
if (ROLE === 'plain' && isPrimary) {
    for (const role of ['tls', 'tlscheck']) {
        if (!hasPair(LISTENERS[role].certs)) continue;
        const child = spawn(process.execPath, [fileURLToPath(import.meta.url)], {
            stdio: 'inherit',
            env: { ...process.env, MORO_ROLE: role },
        });
        child.on('exit', (code, signal) => {
            console.error(`morojs: ${role} process exited (${signal ?? code})`);
        });
        for (const signal of ['SIGTERM', 'SIGINT']) {
            process.on(signal, () => child.kill(signal));
        }
    }
}

// Dataset for /json; a missing file serves an empty list instead of taking
// the worker down.
let dataset = [];
if (isWorker) {
    try {
        dataset = JSON.parse(readFileSync(DATASET_PATH, 'utf8'));
    } catch {}
}

// Postgres for /async-db, /fortunes and the production-stack api, all served
// on :8080. The pool is sized from DATABASE_MAX_CONN across the workers, so
// the cluster as a whole stays inside what Postgres allows.
let pool = null;
if (isWorker && ROLE === 'plain' && process.env.DATABASE_URL) {
    const maxConn = parseInt(process.env.DATABASE_MAX_CONN, 10) || 256;
    pool = new pg.Pool({
        connectionString: process.env.DATABASE_URL,
        max: Math.max(1, Math.floor(maxConn / workers)),
    });
    pool.on('error', () => {});
}

// The production-stack cache-aside goes through the framework's own cache
// adapters: Redis when the stack provides one, shared across the cluster so
// a write on any worker invalidates what every other one reads, and the
// in-process memory adapter otherwise. TTLs are seconds.
let cache = null;
if (isWorker && ROLE === 'plain') {
    cache = process.env.REDIS_URL
        ? new RedisCacheAdapter({ url: process.env.REDIS_URL, keyPrefix: 'httparena:' })
        : new MemoryCacheAdapter();
}
const ITEM_TTL = 1;
const USER_TTL = 30;

function sumQuery(query) {
    let sum = 0;
    for (const key in query) {
        const n = parseInt(query[key], 10);
        if (n === n) sum += n;
    }
    return sum;
}

const EMPTY = { items: [], count: 0 };
const ITEM_COLUMNS = 'id, name, category, price, quantity, active, tags, rating_score, rating_count';
const ASYNC_DB_SQL = `SELECT ${ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3`;
const itemShape = r => ({
    id: r.id, name: r.name, category: r.category,
    price: r.price, quantity: r.quantity, active: r.active,
    tags: r.tags,
    rating: { score: r.rating_score, count: r.rating_count },
});
const dbError = (res, message) => res.status(500).json({ error: message });
const RUNTIME_FORTUNE = 'Additional fortune added at request time.';

// The /json response: the first count items with total = price x quantity x m.
function jsonItems(req) {
    let count = parseInt(req.params.count, 10) || 0;
    if (count < 0) count = 0;
    if (count > dataset.length) count = dataset.length;
    const m = parseInt(req.query.m, 10) || 1;
    const items = new Array(count);
    for (let i = 0; i < count; i++) {
        const d = dataset[i];
        items[i] = {
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m,
        };
    }
    return { items, count };
}

function defineRoutes(app) {
    // A literal body in place of a handler is the framework's documented
    // static route: @morojs/engine answers it without entering JS, the same
    // way Bun's static routes serve the bun entry's /pipeline. It goes out as
    // res.send('ok') would, text/plain.
    app.get('/pipeline').handler('ok');

    // The framework hands the body over parsed: text/plain arrives as a
    // string whether it came with a Content-Length or chunked, so POST adds
    // it to the query sum.
    const baseline11 = (req, res) => {
        let total = sumQuery(req.query);
        if (req.method === 'POST' && typeof req.body === 'string') {
            const n = parseInt(req.body.trim(), 10);
            if (n === n) total += n;
        }
        res.send(String(total));
    };
    app.get('/baseline11').handler(baseline11);
    app.post('/baseline11').handler(baseline11);

    // Behind the gateway proxies, which terminate TLS and h2 and forward this
    // over loopback h1.
    app.get('/baseline2').handler((req, res) => {
        res.send(String(sumQuery(req.query)));
    });

    // An awaited timer suspends the request and frees the thread, so the
    // waits in flight are bounded by memory. The delay is read from the path
    // on every request.
    app.get('/delay/:ms').handler(async (req, res) => {
        const ms = Number.parseInt(req.params.ms, 10);
        if (!Number.isInteger(ms) || ms < 0) {
            res.status(404).send('Not found');
            return;
        }
        if (ms > 0) await new Promise(resolve => setTimeout(resolve, ms));
        res.send(String(ms));
    });

    // json-comp: the framework's compression middleware on this route alone,
    // so no other endpoint pays for the encoder. It negotiates off
    // Accept-Encoding per request and sends the body as is when none is sent,
    // which is what json-tls on :8081 gets. gzip is preferred over brotli:
    // at the middleware's default level it costs about half the CPU of
    // brotli at the default quality for a body one tenth larger, and the
    // profile prices bytes squared against rate. brotli stays available for
    // a client that accepts nothing else.
    app.get('/json/:count')
        .before(middleware.compression({ encodings: ['gzip', 'br'] }))
        .handler((req, res) => {
            res.json(jsonItems(req));
        });

    // 8gbit: the body exactly as it arrived, Content-Length or chunked, sent
    // back as the same bytes. req.rawBody is the framework's undecoded copy.
    app.post('/echo').handler((req, res) => {
        res.setHeader('Content-Type', 'application/octet-stream');
        res.send(req.rawBody ?? Buffer.alloc(0));
    });

    app.get('/async-db').handler(async (req, res) => {
        if (!pool) {
            res.json(EMPTY);
            return;
        }
        const min = parseInt(req.query.min, 10) || 10;
        const max = parseInt(req.query.max, 10) || 50;
        let limit = parseInt(req.query.limit, 10) || 50;
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            const { rows } = await pool.query({ name: 'async-db', text: ASYNC_DB_SQL, values: [min, max, limit] });
            res.json({ items: rows.map(itemShape), count: rows.length });
        } catch {
            res.json(EMPTY);
        }
    });

    // fortunes: Moro has no view layer of its own, so the page goes through
    // EJS directly, a real template engine rendering a separate template file
    // per request, with <%= %> escaping the row that carries a <script> tag.
    app.get('/fortunes').handler(async (req, res) => {
        if (!pool) {
            res.status(500).send('DB not available');
            return;
        }
        try {
            const { rows } = await pool.query({ name: 'fortunes', text: 'SELECT id, message FROM fortune' });
            rows.push({ id: 0, message: RUNTIME_FORTUNE });
            // Ordinal, not locale aware: the seed carries em-dashes and collation
            // rules would order them in a way the profile does not ask for.
            rows.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
            const html = await ejs.renderFile(FORTUNES_VIEW, { fortunes: rows }, { cache: true });
            res.setHeader('Content-Type', 'text/html; charset=utf-8');
            res.send(html);
        } catch {
            res.status(500).send('query failed');
        }
    });

    // production-stack: the edge serves /static/* itself and sends /api/* past
    // the shared JWT verifier first, so nothing here checks a token. What
    // arrives is already authorised and carries X-User-Id.
    app.get('/public/baseline').handler((req, res) => {
        res.send(String(sumQuery(req.query)));
    });
    app.get('/public/json/:count').handler((req, res) => {
        res.json(jsonItems(req));
    });

    // Cache-aside read: the cache first, Postgres on a miss, and the row goes
    // into the cache for a second at most.
    app.get('/api/items/:id').handler(async (req, res) => {
        if (!pool) {
            dbError(res, 'DB not available');
            return;
        }
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) {
            res.sendStatus(404);
            return;
        }
        try {
            const cached = await cache.get('item:' + id);
            if (cached) {
                res.setHeader('X-Cache', 'HIT');
                res.json(cached);
                return;
            }
            const { rows } = await pool.query({
                name: 'item-read',
                text: `SELECT ${ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1`,
                values: [id],
            });
            if (rows.length === 0) {
                res.sendStatus(404);
                return;
            }
            const item = itemShape(rows[0]);
            void cache.set('item:' + id, item, ITEM_TTL);
            res.setHeader('X-Cache', 'MISS');
            res.json(item);
        } catch {
            dbError(res, 'query failed');
        }
    });

    // Write path: the JSON body arrives parsed by the framework. The cache
    // entry goes after the row is written, so the next read misses and
    // repopulates from Postgres. 204 and no body.
    app.post('/api/items/:id').handler(async (req, res) => {
        if (!pool) {
            dbError(res, 'DB not available');
            return;
        }
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) {
            res.sendStatus(404);
            return;
        }
        const body = req.body && typeof req.body === 'object' ? req.body : {};
        try {
            const { rowCount } = await pool.query({
                name: 'item-update',
                text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
                values: [body.name ?? 'Updated', body.price ?? 0, body.quantity ?? 0, id],
            });
            if (rowCount === 0) {
                res.sendStatus(404);
                return;
            }
            await cache.del('item:' + id);
            res.status(204).end();
        } catch {
            dbError(res, 'update failed');
        }
    });

    app.get('/api/me').handler(async (req, res) => {
        if (!pool) {
            dbError(res, 'DB not available');
            return;
        }
        const id = parseInt(req.headers['x-user-id'], 10);
        if (!Number.isFinite(id)) {
            res.sendStatus(401);
            return;
        }
        try {
            const cached = await cache.get('user:' + id);
            if (cached) {
                res.setHeader('X-Cache', 'HIT');
                res.json(cached);
                return;
            }
            const { rows } = await pool.query({
                name: 'user-read',
                text: 'SELECT id, name, email, plan FROM users WHERE id = $1 LIMIT 1',
                values: [id],
            });
            if (rows.length === 0) {
                res.sendStatus(404);
                return;
            }
            const u = rows[0];
            const user = { id: u.id, name: u.name, email: u.email, plan: u.plan };
            void cache.set('user:' + id, user, USER_TTL);
            res.setHeader('X-Cache', 'MISS');
            res.json(user);
        } catch {
            dbError(res, 'query failed');
        }
    });
}

// The listener this process owns. A TLS listener is the engine's own, ALPN
// http/1.1; on :9000 the pair is watched and reloaded on the running listener
// when the files change, connections in flight untouched.
const listener = LISTENERS[ROLE];
const server = { port: listener.port };
if (listener.certs) {
    server.ssl = { ...pairIn(listener.certs), ...(listener.watch ? { watch: true } : {}) };
}

const app = await createApp({
    server: {
        // Every interface: the harness reaches the container through published
        // ports as well as host networking, and Moro's default host is localhost.
        host: '0.0.0.0',
        engine: 'moro',
        requestTracking: { enabled: false },
        requestLogging: { enabled: false },
        ...server,
    },
    performance: { clustering: { enabled: true, workers } },
    // The engine's own RFC 6455 WebSocket support, on the plain listener where
    // the echo profiles run.
    ...(ROLE === 'plain' ? { websocket: { enabled: true } } : {}),
    logger: { level: process.env.LOG_LEVEL || 'warn' },
});
defineRoutes(app);

if (ROLE === 'plain') {
    // echo-ws: a raw namespace, so a text frame arrives as the string it
    // carried and goes back the same way; binary frames likewise.
    app.websocket(
        '/ws',
        {
            message: (socket, text) => {
                socket.send(text);
            },
            binary: (socket, bytes) => {
                socket.send(bytes, true);
            },
        },
        { raw: true }
    );
}

if (ROLE === 'tls') {
    // Static files through the framework's own handler, which stats and
    // reads the file on every request and serves the .br or .gz sidecar on
    // disk when the client accepts it. Behind a path check so the JSON route
    // on this port does not pay for the file lookup.
    const serveStatic = middleware.staticFiles({ root: STATIC_ROOT, prefix: '/static', precompressed: true });
    await app.use((req, res, next) =>
        req.path.startsWith('/static/') ? serveStatic(req, res, next) : next()
    );
}

app.listen();
