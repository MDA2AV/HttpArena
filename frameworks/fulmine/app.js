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
    const express = require('fulmine.js');
    const fs = require('fs');
    const zlib = require('zlib');
    // json-comp counts the bytes twice over, rps * (minBpr/myBpr)^2, so brotli is preferred where
    // the client offers it: q3 is 12% smaller than gzip level 1 here for 24us more per request.
    // Gzip stays for a client that asks only for gzip, where the level is not worth the CPU.
    const GZIP_OPTS = { level: 1 };
    const BROTLI_OPTS = { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 } };

    const app = express();
    app.disable('x-powered-by');
    app.set('etag', false);

    const SERVER_HDR = { 'server': 'fulmine' };
    // built once: the crud read path spread SERVER_HDR into a new object on every request, which
    // is two allocations per read on the busiest route this entry has
    const CACHE_HIT_HDR = { 'server': 'fulmine', 'x-cache': 'HIT' };
    const CACHE_MISS_HDR = { 'server': 'fulmine', 'x-cache': 'MISS' };

    // Dataset
    let datasetItems;
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    // PostgreSQL. Per-worker pool sized so workers x perWorker stays under Postgres
    // max_connections (256 default, 240 leaves a reserve): a flat 4 per worker saturated the
    // server on a 64-core runner and every request paid the contention.
    let pgPool;
    const dbUrl = process.env.DATABASE_URL;
    if (dbUrl) {
        try {
            // the libpq bindings measure fastest of the node drivers at this row count
            // (https://github.com/nigrosimone/postgres-benchmarks); the JS client is the fallback
            let Pool;
            try {
                Pool = require('pg').native.Pool;
            } catch (e) {
                Pool = require('pg').Pool;
            }
            const totalMax = parseInt(process.env.DATABASE_MAX_CONN ?? '', 10) || 256;
            const perWorker = Math.max(1, Math.floor(Math.min(totalMax, 240) / getCPUCount()));
            pgPool = new Pool({ connectionString: dbUrl, max: perWorker });
        } catch (e) {}
    }

    // CRUD cache. The sidecar Redis when the harness provides one: with one process per
    // core an in-process map would fragment the working set 64 ways and barely ever hit.
    // The cached value is the serialized body, so a HIT skips re-serialization too.
    const CRUD_TTL_MS = 200;
    let redis;
    if (process.env.REDIS_URL) {
        try {
            const Redis = require('ioredis');
            redis = new Redis(process.env.REDIS_URL, { enableAutoPipelining: true });
            redis.on('error', () => {});
        } catch (e) {}
    }
    // @redis/client with its server-assisted client-side cache was measured here and is not worth
    // having: crud went from 352k to 211k rps, p99 from 21ms to 44ms, and the CPU this entry used
    // *fell* from 4502% to 3237% with no failed request, so the processes were waiting rather than
    // working. That is the shape of a bottleneck that moved into Redis: tracking makes it hold an
    // invalidation table per key per client and push a message to all sixty-four of them whenever
    // one writes, and this test writes on every cache miss.
    const crudCache = new Map();
    const crudGet = (id) => {
        if (redis) return redis.get('crud:' + id);
        const hit = crudCache.get(id);
        if (!hit) return null;
        if (hit.until <= Date.now()) { crudCache.delete(id); return null; }
        return hit.json;
    };
    const crudSet = (id, json) => {
        if (redis) return redis.set('crud:' + id, json, 'PX', CRUD_TTL_MS);
        crudCache.set(id, { json, until: Date.now() + CRUD_TTL_MS });
    };
    const crudDel = (id) => {
        if (redis) return redis.del('crud:' + id);
        crudCache.delete(id);
    };

    // one shape for the two body-carrying crud verbs, read the way the other POST routes read.
    //
    // The chunks are kept as buffers and joined at the end rather than added to a string as they
    // arrive. Adding them decodes each chunk on its own, so a character whose UTF-8 bytes are split
    // across two chunks becomes a replacement character on both sides of the cut. Nothing complains:
    // the body still parses, it just no longer says what was sent. Measured against express.json()
    // on this shape, the two are the same speed, so the hand-rolled reader is kept only because it
    // answers a bad body with the empty 400 the profile expects.
    function readJsonBody(req, cb) {
        const chunks = [];
        req.on('data', chunk => chunks.push(chunk));
        req.on('end', () => {
            try { cb(null, JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (e) { cb(e); }
        });
    }

    // MIME types for static files
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

    app.get('/pipeline', (req, res) => {
        res.set(SERVER_HDR).type('text/plain').send('ok');
    });

    // shared by the plaintext listener and the TLS one on 8081: same handler, same shapes
    const registerJsonRoute = (target) => target.get('/json/:count', (req, res) => {
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
            // json-comp profile: negotiated per request, nothing without Accept-Encoding
            const ae = req.headers['accept-encoding'] || '';
            if (ae.includes('br')) {
                res.set({ ...SERVER_HDR, 'content-encoding': 'br' })
                    .type('application/json')
                    .send(zlib.brotliCompressSync(body, BROTLI_OPTS));
            } else if (ae.includes('gzip')) {
                res.set({ ...SERVER_HDR, 'content-encoding': 'gzip' })
                    .type('application/json')
                    .send(zlib.gzipSync(body, GZIP_OPTS));
            } else {
                res.set(SERVER_HDR).type('application/json').send(body);
            }
        } else {
            res.status(500).send('No dataset');
        }
    });
    registerJsonRoute(app);

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
            // named, so pg prepares it once per connection and later executions skip the parse:
            // the parameterized form alone re-parses on every call
            const result = await pgPool.query({
                name: 'items-by-price',
                text: 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
                values: [min, max, limit]
            });
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

    const ITEM_COLUMNS = 'id, name, category, price, quantity, active, tags, rating_score, rating_count';
    const itemShape = (r) => ({
        id: r.id, name: r.name, category: r.category,
        price: r.price, quantity: r.quantity, active: r.active,
        tags: r.tags,
        rating: { score: r.rating_score, count: r.rating_count }
    });

    app.get('/crud/items', async (req, res) => {
        if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
        const category = String(req.query.category || 'electronics');
        const page = Math.max(1, parseInt(req.query.page, 10) || 1);
        let limit = parseInt(req.query.limit, 10) || 10;
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            const result = await pgPool.query({
                name: 'crud-list',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3',
                values: [category, limit, (page - 1) * limit]
            });
            const items = result.rows.map(itemShape);
            res.set(SERVER_HDR).type('application/json')
                .send(JSON.stringify({ items, total: items.length, page, limit }));
        } catch (e) {
            res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"query failed"}');
        }
    });

    app.get('/crud/items/:id', async (req, res) => {
        if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(404).set(SERVER_HDR).end();
        try {
            const cached = await crudGet(id);
            if (cached) {
                return res.set(CACHE_HIT_HDR).type('application/json').send(cached);
            }
            const result = await pgPool.query({
                name: 'crud-read',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE id = $1 LIMIT 1',
                values: [id]
            });
            if (result.rows.length === 0) return res.status(404).set(SERVER_HDR).end();
            const json = JSON.stringify(itemShape(result.rows[0]));
            crudSet(id, json);
            res.set(CACHE_MISS_HDR).type('application/json').send(json);
        } catch (e) {
            res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"query failed"}');
        }
    });

    app.post('/crud/items', (req, res) => {
        if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
        readJsonBody(req, async (err, body) => {
            if (err) return res.status(400).set(SERVER_HDR).end();
            try {
                const result = await pgPool.query({
                    name: 'crud-create',
                    text: 'INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) ' +
                        "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
                        'ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id',
                    values: [body.id, body.name ?? 'New Product', body.category ?? 'test', body.price ?? 0, body.quantity ?? 0]
                });
                res.status(201).set(SERVER_HDR).type('application/json').send(JSON.stringify({
                    id: result.rows[0].id, name: body.name, category: body.category,
                    price: body.price, quantity: body.quantity
                }));
            } catch (e) {
                res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"insert failed"}');
            }
        });
    });

    app.put('/crud/items/:id', (req, res) => {
        if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(404).set(SERVER_HDR).end();
        readJsonBody(req, async (err, body) => {
            if (err) return res.status(400).set(SERVER_HDR).end();
            try {
                const result = await pgPool.query({
                    name: 'crud-update',
                    text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
                    values: [body.name ?? 'Updated', body.price ?? 0, body.quantity ?? 0, id]
                });
                if (result.rowCount === 0) return res.status(404).set(SERVER_HDR).end();
                await crudDel(id);
                res.set(SERVER_HDR).type('application/json').send(JSON.stringify({
                    id, name: body.name, price: body.price, quantity: body.quantity
                }));
            } catch (e) {
                res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"update failed"}');
            }
        });
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

    // shared by the plaintext listener and the TLS one on 8081, as the JSON route is: static-tls
    // asks for the same files over TLS
    const registerStaticRoute = (target) => target.get('/static/:filename', (req, res) => {
        const sf = staticFiles[req.params.filename];
        if (!sf) return res.status(404).send('Not found');
        const ae = req.headers['accept-encoding'] || '';
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
            if (err) return res.status(404).send('Not found');
            const headers = { ...SERVER_HDR, 'content-type': sf.ct, 'content-length': String(buf.length) };
            if (encoding) headers['content-encoding'] = encoding;
            res.set(headers).send(buf);
        });
    });
    registerStaticRoute(app);

    // WebSocket echo profiles, on µWS's own WebSocket server through the app's uwsApp handle.
    // Every connection performs µWS's real upgrade handshake; the echo hands the incoming
    // frame straight back without copying it out.
    app.uwsApp.ws('/ws', {
        // dataset echoes are tiny; the cap only guards against a misbehaving client
        maxPayloadLength: 16 * 1024,
        message: (ws, message, isBinary) => {
            ws.send(message, isBinary);
        }
    });

    // json-tls and static-tls profiles: the same two routes over uWS's native TLS on 8081. The
    // certs are mounted by the harness for the TLS profiles; without them there is no listener.
    if (fs.existsSync('/certs/server.key') && fs.existsSync('/certs/server.crt')) {
        const tlsApp = express({
            uwsOptions: {
                key_file_name: '/certs/server.key',
                cert_file_name: '/certs/server.crt'
            }
        });
        tlsApp.disable('x-powered-by');
        tlsApp.set('etag', false);
        registerJsonRoute(tlsApp);
        registerStaticRoute(tlsApp);
        tlsApp.listen(8081);
    }

    app.listen(8080);
}
