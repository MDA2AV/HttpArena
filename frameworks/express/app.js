const cluster = require('cluster');
const os = require('os');

function getCPUCount() {
    try {
        const max = require('fs').readFileSync('/sys/fs/cgroup/cpu.max', 'utf8').trim();
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
} else {
    const express = require('express');
    const fs = require('fs');
    const https = require('node:https');
    const path = require('node:path');
    const compression = require('compression');
    const { engine } = require('express-handlebars');
    const Database = require('better-sqlite3');

    const app = express();
    app.disable('x-powered-by');
    app.set('etag', false);
    // standard mode: compression and static files go through the default middleware with its
    // default settings, nothing hand-rolled
    app.use(compression());
    app.use('/static', express.static('/data/static'));

    // fortunes renders through a view engine, which is what standard mode asks for:
    // the template is its own artifact and Handlebars escapes {{ }} by default.
    app.engine('hbs', engine({ extname: '.hbs', defaultLayout: false }));
    app.set('view engine', 'hbs');
    app.set('views', path.join(__dirname, 'views'));

    const SERVER_HDR = { 'server': 'express' };

    // Dataset
    let datasetItems;
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    // SQLite
    let dbStmt;
    try {
        if (fs.existsSync('/data/benchmark.db')) {
            const db = new Database('/data/benchmark.db', { readonly: true });
            db.pragma('mmap_size=268435456');
            dbStmt = db.prepare('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50');
        }
    } catch (e) {}

    // PostgreSQL
    let pgPool;
    const dbUrl = process.env.DATABASE_URL;
    if (dbUrl) {
        try {
            const { Pool } = require('pg');
            pgPool = new Pool({ connectionString: dbUrl, max: 4 });
            pgPool.on('error', () => {});
        } catch (e) {}
    }

    // Redis, for the crud cache-aside only. One connection per worker, so the cache is
    // shared across the cluster where a per-worker map would not be.
    let redis;
    if (process.env.REDIS_URL) {
        try {
            const Redis = require('ioredis');
            redis = new Redis(process.env.REDIS_URL, { enableAutoPipelining: true });
            redis.on('error', () => {});
        } catch (e) {}
    }

    function sumQuery(query) {
        let sum = 0;
        for (const k in query) {
            const n = parseInt(query[k], 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    app.get('/pipeline', (req, res) => {
        res.set(SERVER_HDR).type('text/plain').send('ok');
    });

    // GET /delay/{ms} — answer after ms milliseconds. setTimeout hands the
    // request back to the event loop, so the wait costs a timer entry and
    // nothing else. `ms` is per-request state, captured in the closure.
    app.get('/delay/:ms', (req, res) => {
        const ms = parseInt(req.params.ms, 10) || 0;
        setTimeout(() => {
            res.set(SERVER_HDR).type('text/plain').send(String(ms));
        }, ms);
    });

    app.get('/json/:count', (req, res) => {
        if (datasetItems) {
            let count = parseInt(req.params.count, 10) || 0;
            if (count < 0) count = 0;
            if (count > datasetItems.length) count = datasetItems.length;
            const m = parseInt(req.query.m) || 1;
            const items = datasetItems.slice(0, count).map(d => ({
                id: d.id, name: d.name, category: d.category,
                price: d.price, quantity: d.quantity, active: d.active,
                tags: d.tags, rating: d.rating,
                total: d.price * d.quantity * m
            }));
            const body = JSON.stringify({ items, count });
            // json-comp negotiation belongs to the compression middleware mounted above
            res.set(SERVER_HDR).type('application/json').send(body);
        } else {
            res.status(500).send('No dataset');
        }
    });

    app.get('/db', (req, res) => {
        if (!dbStmt) {
            return res.set(SERVER_HDR).type('application/json').send('{"items":[],"count":0}');
        }
        const min = parseFloat(req.query.min) || 10;
        const max = parseFloat(req.query.max) || 50;
        const rows = dbStmt.all(min, max);
        const items = rows.map(r => ({
            id: r.id, name: r.name, category: r.category,
            price: r.price, quantity: r.quantity, active: r.active === 1,
            tags: JSON.parse(r.tags),
            rating: { score: r.rating_score, count: r.rating_count }
        }));
        const body = JSON.stringify({ items, count: items.length });
        res.set(SERVER_HDR).type('application/json').send(body);
    });

    app.get('/async-db', async (req, res) => {
        if (!pgPool) {
            return res.set(SERVER_HDR).type('application/json').send('{"items":[],"count":0}');
        }
        const min = parseInt(req.query.min, 10) || 10;
        const max = parseInt(req.query.max, 10) || 50;
        let limit = parseInt(req.query.limit, 10) || 50;
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            const result = await pgPool.query(
                'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
                [min, max, limit]
            );
            const items = result.rows.map(r => ({
                id: r.id, name: r.name, category: r.category,
                price: r.price, quantity: r.quantity, active: r.active,
                tags: r.tags,
                rating: { score: r.rating_score, count: r.rating_count }
            }));
            const body = JSON.stringify({ items, count: items.length });
            res.set(SERVER_HDR).type('application/json').send(body);
        } catch (e) {
            res.set(SERVER_HDR).type('application/json').send('{"items":[],"count":0}');
        }
    });

    // ── crud ────────────────────────────────────────────────────────────────
    const ITEM_COLUMNS =
        'id, name, category, price, quantity, active, tags, rating_score, rating_count';
    const itemShape = (r) => ({
        id: r.id, name: r.name, category: r.category, price: r.price,
        quantity: r.quantity, active: r.active, tags: r.tags,
        rating: { score: r.rating_score, count: r.rating_count }
    });
    const sendJson = (res, body, status = 200, extra = null) =>
        res.status(status).set({ ...SERVER_HDR, ...(extra || {}) }).type('application/json').send(body);
    const dbError = (res, msg, status = 500) => sendJson(res, `{"error":"${msg}"}`, status);

    // The profile reads and writes the same ids, so a long TTL would answer from a copy
    // the writes have already moved past.
    const CRUD_TTL_MS = 200;

    // express.json() is mounted on the two crud routes that carry a body rather than
    // globally: /upload takes a 20MB body it counts as it streams, and a global parser
    // would buffer and parse it.
    const jsonBody = express.json();

    app.get('/crud/items', async (req, res) => {
        if (!pgPool) return dbError(res, 'DB not available');
        const category = req.query.category || 'electronics';
        const page = Math.max(1, parseInt(req.query.page, 10) || 1);
        let limit = parseInt(req.query.limit, 10) || 10;
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            const r = await pgPool.query({
                name: 'crud-list',
                text: `SELECT ${ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3`,
                values: [category, limit, (page - 1) * limit]
            });
            const items = r.rows.map(itemShape);
            sendJson(res, JSON.stringify({ items, total: items.length, page, limit }));
        } catch (e) { dbError(res, 'query failed'); }
    });

    app.post('/crud/items', jsonBody, async (req, res) => {
        if (!pgPool) return dbError(res, 'DB not available');
        const b = req.body;
        if (!b) return dbError(res, 'insert failed');
        try {
            const r = await pgPool.query({
                name: 'crud-create',
                text: 'INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) ' +
                    'VALUES ($1, $2, $3, $4, $5, true, \'["bench"]\', 0, 0) ' +
                    'ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id',
                values: [b.id, b.name ?? 'New Product', b.category ?? 'test', b.price ?? 0, b.quantity ?? 0]
            });
            sendJson(res, JSON.stringify({
                id: r.rows[0].id, name: b.name, category: b.category,
                price: b.price, quantity: b.quantity
            }), 201);
        } catch (e) { dbError(res, 'insert failed'); }
    });

    app.get('/crud/items/:id', async (req, res) => {
        if (!pgPool) return dbError(res, 'DB not available');
        const id = parseInt(req.params.id, 10);
        if (id !== id) return res.status(404).set(SERVER_HDR).end();
        try {
            if (redis) {
                const hit = await redis.get('crud:' + id);
                if (hit) return sendJson(res, hit, 200, { 'x-cache': 'HIT' });
            }
            const r = await pgPool.query({
                name: 'crud-read',
                text: `SELECT ${ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1`,
                values: [id]
            });
            if (r.rows.length === 0) return res.status(404).set(SERVER_HDR).end();
            const body = JSON.stringify(itemShape(r.rows[0]));
            if (redis) redis.set('crud:' + id, body, 'PX', CRUD_TTL_MS);
            sendJson(res, body, 200, { 'x-cache': 'MISS' });
        } catch (e) { dbError(res, 'query failed'); }
    });

    app.put('/crud/items/:id', jsonBody, async (req, res) => {
        if (!pgPool) return dbError(res, 'DB not available');
        const id = parseInt(req.params.id, 10);
        if (id !== id) return res.status(404).set(SERVER_HDR).end();
        const b = req.body;
        if (!b) return dbError(res, 'update failed');
        try {
            const r = await pgPool.query({
                name: 'crud-update',
                text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
                values: [b.name ?? 'Updated', b.price ?? 0, b.quantity ?? 0, id]
            });
            if (r.rowCount === 0) return res.status(404).set(SERVER_HDR).end();
            if (redis) await redis.del('crud:' + id);
            sendJson(res, JSON.stringify({ id, name: b.name, price: b.price, quantity: b.quantity }));
        } catch (e) { dbError(res, 'update failed'); }
    });

    // ── fortunes ────────────────────────────────────────────────────────────
    // Row 11 of the seed carries a <script> tag; leaving it as text is the profile's
    // load-bearing check, and it is the view engine's default escape that does it.
    const RUNTIME_FORTUNE = 'Additional fortune added at request time.';

    app.get('/fortunes', async (req, res) => {
        if (!pgPool) return res.status(500).set(SERVER_HDR).type('text/plain').send('DB not available');
        try {
            const r = await pgPool.query({ name: 'fortunes', text: 'SELECT id, message FROM fortune' });
            const fortunes = r.rows.map(x => ({ id: x.id, message: x.message }));
            fortunes.push({ id: 0, message: RUNTIME_FORTUNE });
            // Ordinal, not locale aware: the seed carries em-dashes and collation rules
            // would order them in a way the profile does not ask for.
            fortunes.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
            res.set(SERVER_HDR).type('text/html; charset=utf-8').render('fortunes', { fortunes });
        } catch (e) {
            res.status(500).set(SERVER_HDR).type('text/plain').send('query failed');
        }
    });

    app.post('/upload', (req, res) => {
        let size = 0;
        req.on('data', chunk => size += chunk.length);
        req.on('end', () => {
            res.set(SERVER_HDR).type('text/plain').send(String(size));
        });
    });

    app.get('/baseline2', (req, res) => {
        res.set(SERVER_HDR).type('text/plain').send(String(sumQuery(req.query)));
    });

    app.all('/baseline11', (req, res) => {
        const querySum = sumQuery(req.query);
        if (req.method === 'POST') {
            let body = '';
            req.on('data', chunk => body += chunk);
            req.on('end', () => {
                let total = querySum;
                const n = parseInt(body.trim(), 10);
                if (n === n) total += n;
                res.set(SERVER_HDR).type('text/plain').send(String(total));
            });
        } else {
            res.set(SERVER_HDR).type('text/plain').send(String(querySum));
        }
    });

    app.listen(8080);

    // json-tls and static-tls on 8081, the same app behind a TLS server. Every worker
    // binds it exactly as they all bind 8080, so the cluster shares the port rather than
    // one process carrying it. The harness only mounts /certs for the TLS profiles.
    const CERT = '/certs/server.crt';
    const KEY = '/certs/server.key';
    if (fs.existsSync(CERT) && fs.existsSync(KEY)) {
        https.createServer({
            key: fs.readFileSync(KEY),
            cert: fs.readFileSync(CERT)
        }, app).listen(8081);
    }
}
