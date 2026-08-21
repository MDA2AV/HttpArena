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
    const { Server } = require('hyper-express');
    const fs = require('fs');
    const zlib = require('zlib');
    // level 1: the arena measures throughput of compressed JSON, and the payloads are small
    // enough that a higher level buys bytes nobody counts
    const GZIP_OPTS = { level: 1 };

    const SERVER_HDR = 'hyper-express';

    // Dataset
    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    // PostgreSQL, for async-db, api-4/api-16, crud and fortunes. The pool is per worker
    // and this entry forks one per core, so the harness's budget is split across them
    // rather than opened by each.
    let pgPool;
    if (process.env.DATABASE_URL) {
        try {
            const { Pool } = require('pg');
            pgPool = new Pool({ connectionString: process.env.DATABASE_URL, max: 4 });
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

    const MIME_TYPES = {
        '.css': 'text/css', '.js': 'application/javascript', '.html': 'text/html',
        '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.json': 'application/json',
    };

    // No file data lives in memory, per the arena rules: this scans names only, so a request
    // knows which pre-compressed variants exist and the content type. The bytes are read from
    // disk on every request.
    const staticFiles = {};
    try {
        for (const name of fs.readdirSync('/data/static')) {
            if (name.endsWith('.br') || name.endsWith('.gz')) continue;
            const ext = name.slice(name.lastIndexOf('.'));
            staticFiles[name] = {
                path: `/data/static/${name}`,
                br: fs.existsSync(`/data/static/${name}.br`),
                gz: fs.existsSync(`/data/static/${name}.gz`),
                ct: MIME_TYPES[ext] || 'application/octet-stream'
            };
        }
    } catch (e) {}

    function sumQuery(query) {
        let sum = 0;
        for (const k in query) {
            const n = parseInt(query[k], 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    const ITEM_COLUMNS =
        'id, name, category, price, quantity, active, tags, rating_score, rating_count';
    const itemShape = (r) => ({
        id: r.id, name: r.name, category: r.category, price: r.price,
        quantity: r.quantity, active: r.active, tags: r.tags,
        rating: { score: r.rating_score, count: r.rating_count }
    });

    function sendJson(response, body, status = 200, extra = null) {
        response.status(status).header('server', SERVER_HDR).type('application/json');
        if (extra) for (const k in extra) response.header(k, extra[k]);
        response.send(body);
    }
    const dbError = (response, msg, status = 500) => sendJson(response, `{"error":"${msg}"}`, status);

    // The profile reads and writes the same ids, so a long TTL would answer from a copy
    // the writes have already moved past.
    const CRUD_TTL_MS = 200;

    // ── fortunes ────────────────────────────────────────────────────────────────
    // Tuned mode, so the page is emitted by hand rather than through an engine. Row 11
    // of the seed carries a <script> tag and it has to leave here as text.
    const RUNTIME_FORTUNE = 'Additional fortune added at request time.';
    const ESCAPE = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
    const escapeHtml = (s) => s.replace(/[&<>"']/g, c => ESCAPE[c]);

    async function readJson(request) {
        try { return JSON.parse(await request.text()); } catch (e) { return null; }
    }

    function registerRoutes(server) {
        server.get('/pipeline', (request, response) => {
            response.header('server', SERVER_HDR).type('text/plain').send('ok');
        });

        server.get('/json/:count', (request, response) => {
            let count = parseInt(request.path_parameters.count, 10) || 0;
            if (count < 0) count = 0;
            if (count > datasetItems.length) count = datasetItems.length;
            const m = parseInt(request.query_parameters.m, 10) || 1;
            const items = datasetItems.slice(0, count).map(d => ({
                id: d.id, name: d.name, category: d.category,
                price: d.price, quantity: d.quantity, active: d.active,
                tags: d.tags, rating: d.rating,
                total: d.price * d.quantity * m
            }));
            const body = JSON.stringify({ items, count });
            // json-comp profile: negotiated per request. hyper-express ships no response
            // compression of its own, so the encoding is picked here and nothing is sent
            // compressed without Accept-Encoding.
            const ae = request.headers['accept-encoding'] || '';
            if (ae.includes('gzip')) {
                response.header('server', SERVER_HDR)
                    .header('content-encoding', 'gzip')
                    .type('application/json')
                    .send(zlib.gzipSync(body, GZIP_OPTS));
            } else if (ae.includes('br')) {
                response.header('server', SERVER_HDR)
                    .header('content-encoding', 'br')
                    .type('application/json')
                    .send(zlib.brotliCompressSync(body, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 } }));
            } else {
                response.header('server', SERVER_HDR).type('application/json').send(body);
            }
        });

        server.get('/async-db', async (request, response) => {
            if (!pgPool) {
                return response.header('server', SERVER_HDR).type('application/json').send('{"items":[],"count":0}');
            }
            const q = request.query_parameters;
            const min = parseInt(q.min, 10) || 10;
            const max = parseInt(q.max, 10) || 50;
            let limit = parseInt(q.limit, 10) || 50;
            if (limit < 1) limit = 1;
            if (limit > 50) limit = 50;
            try {
                const r = await pgPool.query({
                    name: 'async-db',
                    text: `SELECT ${ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3`,
                    values: [min, max, limit]
                });
                const items = r.rows.map(itemShape);
                sendJson(response, JSON.stringify({ items, count: items.length }));
            } catch (e) {
                response.header('server', SERVER_HDR).type('application/json').send('{"items":[],"count":0}');
            }
        });

        // ── crud ────────────────────────────────────────────────────────────────
        server.get('/crud/items', async (request, response) => {
            if (!pgPool) return dbError(response, 'DB not available');
            const q = request.query_parameters;
            const category = q.category || 'electronics';
            const page = Math.max(1, parseInt(q.page, 10) || 1);
            let limit = parseInt(q.limit, 10) || 10;
            if (limit < 1) limit = 1;
            if (limit > 50) limit = 50;
            try {
                const r = await pgPool.query({
                    name: 'crud-list',
                    text: `SELECT ${ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3`,
                    values: [category, limit, (page - 1) * limit]
                });
                const items = r.rows.map(itemShape);
                sendJson(response, JSON.stringify({ items, total: items.length, page, limit }));
            } catch (e) { dbError(response, 'query failed'); }
        });

        server.post('/crud/items', async (request, response) => {
            if (!pgPool) return dbError(response, 'DB not available');
            const b = await readJson(request);
            if (!b) return dbError(response, 'insert failed');
            try {
                const r = await pgPool.query({
                    name: 'crud-create',
                    text: 'INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) ' +
                        'VALUES ($1, $2, $3, $4, $5, true, \'["bench"]\', 0, 0) ' +
                        'ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id',
                    values: [b.id, b.name ?? 'New Product', b.category ?? 'test', b.price ?? 0, b.quantity ?? 0]
                });
                sendJson(response, JSON.stringify({
                    id: r.rows[0].id, name: b.name, category: b.category,
                    price: b.price, quantity: b.quantity
                }), 201);
            } catch (e) { dbError(response, 'insert failed'); }
        });

        // Cache-aside on Redis where the harness provides it - crud is the one profile
        // that does.
        server.get('/crud/items/:id', async (request, response) => {
            if (!pgPool) return dbError(response, 'DB not available');
            const id = parseInt(request.path_parameters.id, 10);
            if (id !== id) return response.status(404).header('server', SERVER_HDR).send('');
            try {
                if (redis) {
                    const hit = await redis.get('crud:' + id);
                    if (hit) return sendJson(response, hit, 200, { 'x-cache': 'HIT' });
                }
                const r = await pgPool.query({
                    name: 'crud-read',
                    text: `SELECT ${ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1`,
                    values: [id]
                });
                if (r.rows.length === 0) return response.status(404).header('server', SERVER_HDR).send('');
                const body = JSON.stringify(itemShape(r.rows[0]));
                if (redis) redis.set('crud:' + id, body, 'PX', CRUD_TTL_MS);
                sendJson(response, body, 200, { 'x-cache': 'MISS' });
            } catch (e) { dbError(response, 'query failed'); }
        });

        server.put('/crud/items/:id', async (request, response) => {
            if (!pgPool) return dbError(response, 'DB not available');
            const id = parseInt(request.path_parameters.id, 10);
            if (id !== id) return response.status(404).header('server', SERVER_HDR).send('');
            const b = await readJson(request);
            if (!b) return dbError(response, 'update failed');
            try {
                const r = await pgPool.query({
                    name: 'crud-update',
                    text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
                    values: [b.name ?? 'Updated', b.price ?? 0, b.quantity ?? 0, id]
                });
                if (r.rowCount === 0) return response.status(404).header('server', SERVER_HDR).send('');
                if (redis) await redis.del('crud:' + id);
                sendJson(response, JSON.stringify({ id, name: b.name, price: b.price, quantity: b.quantity }));
            } catch (e) { dbError(response, 'update failed'); }
        });

        server.get('/fortunes', async (request, response) => {
            if (!pgPool) {
                return response.status(500).header('server', SERVER_HDR).type('text/plain').send('DB not available');
            }
            try {
                const r = await pgPool.query({ name: 'fortunes', text: 'SELECT id, message FROM fortune' });
                const all = r.rows.map(x => ({ id: x.id, message: x.message }));
                all.push({ id: 0, message: RUNTIME_FORTUNE });
                // Ordinal, not locale aware: the seed carries em-dashes and collation rules
                // would order them in a way the profile does not ask for.
                all.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
                let body = '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>' +
                    '<tr><th>id</th><th>message</th></tr>';
                for (const f of all) body += '<tr><td>' + f.id + '</td><td>' + escapeHtml(f.message) + '</td></tr>';
                body += '</table></body></html>';
                response.header('server', SERVER_HDR).type('text/html; charset=utf-8').send(body);
            } catch (e) {
                response.status(500).header('server', SERVER_HDR).type('text/plain').send('query failed');
            }
        });

        // The request is a lazy Readable: counting bytes never needs the 20 MB body in memory,
        // which is what request.buffer() would cost
        server.post('/upload', (request, response) => {
            let size = 0;
            request.on('data', chunk => size += chunk.length);
            request.on('end', () => {
                response.header('server', SERVER_HDR).type('text/plain').send(String(size));
            });
        });

        server.get('/baseline2', (request, response) => {
            response.header('server', SERVER_HDR).type('text/plain').send(String(sumQuery(request.query_parameters)));
        });

        server.any('/baseline11', async (request, response) => {
            let total = sumQuery(request.query_parameters);
            if (request.method === 'POST') {
                const n = parseInt((await request.text()).trim(), 10);
                if (n === n) total += n;
            }
            response.header('server', SERVER_HDR).type('text/plain').send(String(total));
        });

        server.get('/static/:filename', (request, response) => {
            const sf = staticFiles[request.path_parameters.filename];
            if (!sf) return response.status(404).header('server', SERVER_HDR).send('Not found');
            const ae = request.headers['accept-encoding'] || '';
            let path = sf.path;
            let encoding = null;
            if (sf.br && ae.includes('br')) {
                path += '.br';
                encoding = 'br';
            } else if (sf.gz && ae.includes('gzip')) {
                path += '.gz';
                encoding = 'gzip';
            }
            fs.readFile(path, (err, buf) => {
                if (err) return response.status(404).header('server', SERVER_HDR).send('Not found');
                response.header('server', SERVER_HDR).header('content-type', sf.ct);
                if (encoding) response.header('content-encoding', encoding);
                response.send(buf);
            });
        });

        return server;
    }

    // max_body_length defaults to 250 KB and answers 413 above it, so the upload profile,
    // which posts up to 20 MB, needs the cap raised. Every worker binds :8080 on its own:
    // uWebSockets.js shares the port between processes unless exclusive_port is asked for.
    const OPTIONS = { max_body_length: 32 * 1024 * 1024 };

    registerRoutes(new Server(OPTIONS)).listen(8080);

    // json-tls and static-tls on 8081. hyper-express takes its TLS material through the
    // uWS options at construction rather than a separate https server, so the port is a
    // second Server carrying the same routes. Every worker binds it, the same way they
    // all bind 8080, so the listener is spread across the cluster rather than parked on
    // one process. The harness only mounts /certs for the TLS profiles.
    const CERT = '/certs/server.crt';
    const KEY = '/certs/server.key';
    if (fs.existsSync(CERT) && fs.existsSync(KEY)) {
        registerRoutes(new Server({
            ...OPTIONS,
            key_file_name: KEY,
            cert_file_name: CERT
        })).listen(8081);
    }
}
