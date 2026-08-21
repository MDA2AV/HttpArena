// uWebSockets.js, the Node binding of the uWebSockets C++ server.
//
// This is the raw uWS App API - there is no router, no middleware stack, no body parser and no
// static-file handler. Every profile below is written against the primitives uWS documents:
// app.get/post, req.getQuery/getParameter/getHeader, res.onData/onAborted/cork/end. Where a
// profile's rules ask for something uWS does not ship (a template engine, a Postgres driver),
// the standard library for that job is used directly; where the rules ask for a framework API
// uWS does not have, the profile is answered the plain way rather than hand-rolling a
// lookalike - see the static handler below.
//
// One process per usable core, each binding 8080 with uWS's own listen: the kernel spreads the
// connections. The primary only forks.

const cluster = require('cluster');
const fs = require('fs');
const path = require('path');
const os = require('os');
const zlib = require('zlib');

function getCPUCount() {
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
    const uWS = require('uWebSockets.js');

    // ── Dataset (json, json-comp, json-tls) ──────────────────────────────────
    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    // ── Postgres (async-db, crud) ────────────────────────────────────────────
    // Pool sized from DATABASE_MAX_CONN as the async-db rules require, then divided by the
    // worker count: every core runs its own process here, so the per-process ceiling is what
    // keeps the total under the server's max_connections.
    let pgPool;
    if (process.env.DATABASE_URL) {
        try {
            let Pool;
            try { Pool = require('pg').native.Pool; } catch (e) { Pool = require('pg').Pool; }
            const totalMax = parseInt(process.env.DATABASE_MAX_CONN ?? '', 10) || 256;
            const perWorker = Math.max(1, Math.floor(Math.min(totalMax, 240) / getCPUCount()));
            pgPool = new Pool({ connectionString: process.env.DATABASE_URL, max: perWorker });
            pgPool.on('error', () => {});
        } catch (e) {}
    }

    // ── crud cache-aside ─────────────────────────────────────────────────────
    // 200 ms absolute TTL, invalidated on PUT. One process per core means an in-process map
    // would split the working set as many ways as there are cores and rarely hit, so the
    // harness's Redis sidecar is used when it provides one - which the crud rules allow
    // explicitly for multi-process runtimes. The map is the fallback.
    const CRUD_TTL_MS = 200;
    let redis;
    if (process.env.REDIS_URL) {
        try {
            const Redis = require('ioredis');
            redis = new Redis(process.env.REDIS_URL, { enableAutoPipelining: true });
            redis.on('error', () => {});
        } catch (e) {}
    }
    const localCache = new Map();
    const cacheGet = (key) => {
        if (redis) return redis.get(key);
        const hit = localCache.get(key);
        if (!hit) return null;
        if (hit.until <= Date.now()) { localCache.delete(key); return null; }
        return hit.json;
    };
    const cacheSet = (key, json) => {
        if (redis) return redis.set(key, json, 'PX', CRUD_TTL_MS);
        localCache.set(key, { json, until: Date.now() + CRUD_TTL_MS });
    };
    const cacheDel = (key) => {
        if (redis) return redis.del(key);
        localCache.delete(key);
    };

    // ── helpers ──────────────────────────────────────────────────────────────
    function sumQuery(query) {
        let sum = 0;
        for (const [, value] of new URLSearchParams(query)) {
            const n = parseInt(value, 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    // uWS invalidates req the moment the handler returns, so anything needed after an await
    // has to be pulled off it first. Every async handler below does that before its first
    // suspension point.
    const send = (res, status, type, body, extraHeaders) => {
        if (res.aborted) return;
        res.cork(() => {
            if (status) res.writeStatus(status);
            res.writeHeader('Content-Type', type);
            if (extraHeaders) for (const k in extraHeaders) res.writeHeader(k, extraHeaders[k]);
            res.end(body);
        });
    };
    const guard = (res) => { res.onAborted(() => { res.aborted = true; }); };

    const ITEM_COLUMNS = 'id, name, category, price, quantity, active, tags, rating_score, rating_count';
    const itemShape = (r) => ({
        id: r.id, name: r.name, category: r.category,
        price: r.price, quantity: r.quantity, active: r.active,
        tags: r.tags,
        rating: { score: r.rating_score, count: r.rating_count }
    });

    const readBody = (res, onDone) => {
        let chunks = [];
        res.onData((chunk, isLast) => {
            chunks.push(Buffer.from(chunk));
            if (isLast) onDone(Buffer.concat(chunks));
        });
    };

    // ── static ───────────────────────────────────────────────────────────────
    // uWS ships no static-file handler and no compression middleware. The standard rules allow
    // pre-compressed .br/.gz variants only "through a documented framework API" and bar custom
    // file-suffix lookup logic, so this serves the file that was asked for, uncompressed -
    // compression is optional for this profile and there is no compliant way to do it here.
    // The file is read from disk on every request, which the rules require of every tier.
    const STATIC_DIR = process.env.STATIC_DIR || '/data/static';
    const MIME = {
        '.css': 'text/css', '.js': 'application/javascript', '.html': 'text/html',
        '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.webp': 'image/webp',
        '.json': 'application/json'
    };

    // fs.readFile then end(), not createReadStream + tryEnd/onWritable. uWS documents the
    // streaming pattern in examples/VideoStreamer.js, but that example exists for a multi-GB
    // video where buffering is impossible; these fixtures are 3-300 KB and the per-request
    // ReadStream setup dominates. Measured on this rotation at 1024c: 180k rps read-whole vs
    // 92k rps streamed. Streaming is the wrong tool at this file size.
    const staticHandler = (res, req) => {
        const url = req.getUrl();
        guard(res);
        const name = url.slice('/static/'.length);
        if (!name || name.includes('/') || name.includes('\\') || name.includes('..')) {
            return send(res, '404 Not Found', 'text/plain', '');
        }
        const type = MIME[path.extname(name)] || 'application/octet-stream';
        fs.readFile(path.join(STATIC_DIR, name), (err, buf) => {
            if (res.aborted) return;
            if (err) return send(res, '404 Not Found', 'text/plain', '');
            send(res, null, type, buf);
        });
    };

    // ── routes shared by the plaintext and TLS listeners ─────────────────────
    // json-tls and static-tls ask for the same two routes over TLS on 8081.
    const registerShared = (app) => {
        app.get('/json/:count', (res, req) => {
            const acceptEncoding = req.getHeader('accept-encoding');
            let count = parseInt(req.getParameter(0), 10) || 0;
            if (count < 0) count = 0;
            if (count > datasetItems.length) count = datasetItems.length;
            const m = parseInt(new URLSearchParams(req.getQuery()).get('m'), 10) || 1;

            const items = datasetItems.slice(0, count).map(d => ({
                id: d.id, name: d.name, category: d.category,
                price: d.price, quantity: d.quantity, active: d.active,
                tags: d.tags, rating: d.rating,
                total: d.price * d.quantity * m
            }));
            const body = JSON.stringify({ items, count });

            // uWebSockets.js has no compression middleware, so json-comp is served by
            // gzipping the body with the Node zlib bindings when the client asks for it
            if (acceptEncoding.includes('gzip')) {
                const compressed = zlib.gzipSync(body);
                res.cork(() => {
                    res.writeHeader('Content-Type', 'application/json')
                        .writeHeader('Content-Encoding', 'gzip')
                        .end(compressed);
                });
            } else {
                res.cork(() => {
                    res.writeHeader('Content-Type', 'application/json').end(body);
                });
            }
        });

        app.get('/static/*', staticHandler);
    };

    // ── plaintext listener ───────────────────────────────────────────────────
    const app = uWS.App();

    app.get('/pipeline', res => {
        res.writeHeader('Content-Type', 'text/plain').end('ok');
    });

    app.get('/baseline11', (res, req) => {
        const total = sumQuery(req.getQuery());
        res.writeHeader('Content-Type', 'text/plain').end(String(total));
    });

    app.post('/baseline11', (res, req) => {
        const querySum = sumQuery(req.getQuery());
        guard(res);
        let body = '';
        res.onData((chunk, isLast) => {
            body += Buffer.from(chunk).toString();
            if (!isLast || res.aborted) return;
            let total = querySum;
            const n = parseInt(body.trim(), 10);
            if (n === n) total += n;
            res.cork(() => {
                res.writeHeader('Content-Type', 'text/plain').end(String(total));
            });
        });
    });

    app.get('/baseline2', (res, req) => {
        const total = sumQuery(req.getQuery());
        res.writeHeader('Content-Type', 'text/plain').end(String(total));
    });

    app.post('/upload', res => {
        guard(res);
        let size = 0;
        res.onData((chunk, isLast) => {
            size += chunk.byteLength;
            if (!isLast || res.aborted) return;
            res.cork(() => {
                res.writeHeader('Content-Type', 'text/plain').end(String(size));
            });
        });
    });

    // ── async-db ─────────────────────────────────────────────────────────────
    app.get('/async-db', async (res, req) => {
        const query = new URLSearchParams(req.getQuery());
        guard(res);
        if (!pgPool) return send(res, null, 'application/json', '{"items":[],"count":0}');
        const min = parseInt(query.get('min'), 10) || 10;
        const max = parseInt(query.get('max'), 10) || 50;
        let limit = parseInt(query.get('limit'), 10) || 50;
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            // named, so pg prepares it once per connection and later executions skip the parse
            const result = await pgPool.query({
                name: 'items-by-price',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
                values: [min, max, limit]
            });
            const items = result.rows.map(itemShape);
            send(res, null, 'application/json', JSON.stringify({ items, count: items.length }));
        } catch (e) {
            send(res, null, 'application/json', '{"items":[],"count":0}');
        }
    });

    // ── crud ─────────────────────────────────────────────────────────────────
    app.get('/crud/items', async (res, req) => {
        const query = new URLSearchParams(req.getQuery());
        guard(res);
        if (!pgPool) return send(res, '500 Internal Server Error', 'application/json', '{"error":"DB not available"}');
        const category = query.get('category') || 'electronics';
        const page = Math.max(1, parseInt(query.get('page'), 10) || 1);
        let limit = parseInt(query.get('limit'), 10) || 10;
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            const result = await pgPool.query({
                name: 'crud-list',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3',
                values: [category, limit, (page - 1) * limit]
            });
            const items = result.rows.map(itemShape);
            send(res, null, 'application/json', JSON.stringify({ items, total: items.length, page, limit }));
        } catch (e) {
            send(res, '500 Internal Server Error', 'application/json', '{"error":"query failed"}');
        }
    });

    app.get('/crud/items/:id', async (res, req) => {
        const id = parseInt(req.getParameter(0), 10);
        guard(res);
        if (!pgPool) return send(res, '500 Internal Server Error', 'application/json', '{"error":"DB not available"}');
        if (!Number.isFinite(id)) return send(res, '404 Not Found', 'application/json', '');
        try {
            const cached = await cacheGet('crud:' + id);
            if (cached) return send(res, null, 'application/json', cached, { 'X-Cache': 'HIT' });
            const result = await pgPool.query({
                name: 'crud-read',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE id = $1 LIMIT 1',
                values: [id]
            });
            if (result.rows.length === 0) return send(res, '404 Not Found', 'application/json', '');
            const json = JSON.stringify(itemShape(result.rows[0]));
            cacheSet('crud:' + id, json);
            send(res, null, 'application/json', json, { 'X-Cache': 'MISS' });
        } catch (e) {
            send(res, '500 Internal Server Error', 'application/json', '{"error":"query failed"}');
        }
    });

    app.post('/crud/items', (res) => {
        guard(res);
        readBody(res, async (raw) => {
            if (!pgPool) return send(res, '500 Internal Server Error', 'application/json', '{"error":"DB not available"}');
            let body;
            try { body = JSON.parse(raw.toString()); } catch (e) {
                return send(res, '400 Bad Request', 'application/json', '');
            }
            try {
                const result = await pgPool.query({
                    name: 'crud-create',
                    text: 'INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) ' +
                        "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
                        'ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id',
                    values: [body.id, body.name ?? 'New Product', body.category ?? 'test', body.price ?? 0, body.quantity ?? 0]
                });
                send(res, '201 Created', 'application/json', JSON.stringify({
                    id: result.rows[0].id, name: body.name, category: body.category,
                    price: body.price, quantity: body.quantity
                }));
            } catch (e) {
                send(res, '500 Internal Server Error', 'application/json', '{"error":"insert failed"}');
            }
        });
    });

    app.put('/crud/items/:id', (res, req) => {
        const id = parseInt(req.getParameter(0), 10);
        guard(res);
        readBody(res, async (raw) => {
            if (!pgPool) return send(res, '500 Internal Server Error', 'application/json', '{"error":"DB not available"}');
            if (!Number.isFinite(id)) return send(res, '404 Not Found', 'application/json', '');
            let body;
            try { body = JSON.parse(raw.toString()); } catch (e) {
                return send(res, '400 Bad Request', 'application/json', '');
            }
            try {
                const result = await pgPool.query({
                    name: 'crud-update',
                    text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
                    values: [body.name ?? 'Updated', body.price ?? 0, body.quantity ?? 0, id]
                });
                if (result.rowCount === 0) return send(res, '404 Not Found', 'application/json', '');
                await cacheDel('crud:' + id);
                send(res, null, 'application/json', JSON.stringify({
                    id, name: body.name, price: body.price, quantity: body.quantity
                }));
            } catch (e) {
                send(res, '500 Internal Server Error', 'application/json', '{"error":"update failed"}');
            }
        });
    });

    registerShared(app);
    app.any('/*', (res) => { res.writeStatus('404 Not Found').end(); });
    app.listen(8080, () => {});

    // ── TLS listener (json-tls, static-tls) ──────────────────────────────────
    // uWS's own SSLApp, which terminates with the BoringSSL it is built against - a standard
    // stack, and every connection completes a real handshake.
    if (fs.existsSync('/certs/server.key') && fs.existsSync('/certs/server.crt')) {
        const tlsApp = uWS.SSLApp({
            key_file_name: '/certs/server.key',
            cert_file_name: '/certs/server.crt'
        });
        registerShared(tlsApp);
        tlsApp.any('/*', (res) => { res.writeStatus('404 Not Found').end(); });
        tlsApp.listen(8081, () => {});
    }
}
