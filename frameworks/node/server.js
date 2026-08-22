// node:http with nothing on top: no framework and no router. This is the floor the
// node framework entries are read against.
//
// The only dependencies are the two drivers the database profiles cannot be run
// without - pg for Postgres and ioredis for the crud cache. node ships neither,
// unlike bun, and a hand-written Postgres wire protocol would be a stunt rather
// than an entry. Nothing else is on top: still no framework, still no router.
const cluster = require('node:cluster');
const http = require('node:http');
const https = require('node:https');
const os = require('node:os');
const fs = require('node:fs');
const path_ = require('node:path');
const zlib = require('node:zlib');

// The container is pinned to a cpuset or a cpu quota, so availableParallelism()
// alone would fork one worker per host core. Same helper as the other node entries.
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
} else {
    // A missing dataset serves an empty list instead of taking the worker down
    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    const SERVER_HDR = 'node';

    // Postgres and Redis are only wired for the profiles that use them, so both
    // stay null otherwise and the handlers answer without touching them. The pool
    // is per worker and this entry forks one per core, so the harness's
    // DATABASE_MAX_CONN is split across them rather than opened by each.
    let pgPool = null, redis = null;
    if (process.env.DATABASE_URL) {
        const { Pool } = require('pg');
        const per = Math.max(1, Math.floor(
            (parseInt(process.env.DATABASE_MAX_CONN, 10) || 256) / getCPUCount()));
        pgPool = new Pool({ connectionString: process.env.DATABASE_URL, max: per });
        pgPool.on('error', () => {});
    }
    if (process.env.REDIS_URL) {
        const Redis = require('ioredis');
        redis = new Redis(process.env.REDIS_URL, { enableAutoPipelining: true });
        redis.on('error', () => {});
    }

    const ITEM_COLUMNS =
        'id, name, category, price, quantity, active, tags, rating_score, rating_count';
    const itemShape = (r) => ({
        id: r.id, name: r.name, category: r.category, price: r.price,
        quantity: r.quantity, active: r.active, tags: r.tags,
        rating: { score: r.rating_score, count: r.rating_count }
    });

    function sendJson(res, body, status = 200, extra = null) {
        const h = {
            'content-type': 'application/json',
            'content-length': Buffer.byteLength(body),
            'server': SERVER_HDR
        };
        if (extra) Object.assign(h, extra);
        res.writeHead(status, h);
        res.end(body);
    }
    const sendStatus = (res, status) => { res.writeHead(status, { 'server': SERVER_HDR }); res.end(); };
    const dbError = (res, msg, status = 500) => sendJson(res, '{"error":"' + msg + '"}', status);

    // The two body-carrying crud verbs. Small JSON, so it is collected before it
    // is parsed - unlike /upload, which is counted as it streams.
    function readJson(req, cb) {
        let body = '';
        req.setEncoding('utf8');
        req.on('data', c => body += c);
        req.on('end', () => { try { cb(JSON.parse(body)); } catch { cb(null); } });
    }

    function sendText(res, body) {
        res.writeHead(200, {
            'content-type': 'text/plain',
            'content-length': Buffer.byteLength(body),
            'server': SERVER_HDR
        });
        res.end(body);
    }

    // No querystring module and no URL object: the profiles send a handful of
    // integer parameters, and parsing them by hand is the whole cost here.
    function sumQuery(query) {
        let sum = 0;
        for (const pair of query.split('&')) {
            const eq = pair.indexOf('=');
            if (eq < 0) continue;
            const n = parseInt(pair.slice(eq + 1), 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    function queryValue(query, name) {
        for (const pair of query.split('&')) {
            if (pair.startsWith(name) && pair[name.length] === '=') {
                return pair.slice(name.length + 1);
            }
        }
        return '';
    }

    function json(req, res, path, query) {
        let count = parseInt(path.slice(6), 10) || 0;
        if (count < 0) count = 0;
        if (count > datasetItems.length) count = datasetItems.length;
        const m = parseInt(queryValue(query, 'm'), 10) || 1;
        const items = datasetItems.slice(0, count).map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m
        }));
        const body = JSON.stringify({ items, count });

        // json-comp: node:http negotiates nothing, so Accept-Encoding is read here,
        // per request, with the zlib defaults. Nothing at all when it is not asked for
        const accept = req.headers['accept-encoding'];
        if (accept !== undefined && accept.includes('gzip')) {
            const gz = zlib.gzipSync(body);
            res.writeHead(200, {
                'content-type': 'application/json',
                'content-encoding': 'gzip',
                'vary': 'accept-encoding',
                'content-length': gz.length,
                'server': SERVER_HDR
            });
            res.end(gz);
            return;
        }
        res.writeHead(200, {
            'content-type': 'application/json',
            'content-length': Buffer.byteLength(body),
            'server': SERVER_HDR
        });
        res.end(body);
    }

    // ── static ──────────────────────────────────────────────────────────────
    // Content-Type from an explicit table: the profile checks the header on
    // woff2 and webp among others. Streamed off disk per request with no cache
    // between them, which is what the profile requires of a framework entry.
    // This entry is `standard`, so the .br/.gz files beside the originals are
    // left alone - hand-rolled suffix lookup is a tuned technique and node:http
    // has no static handler to negotiate them for us.
    const MIME = {
        '.css': 'text/css', '.js': 'text/javascript', '.html': 'text/html',
        '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.webp': 'image/webp',
        '.json': 'application/json'
    };

    function serveStatic(res, path) {
        const name = path.slice(8);
        if (!name || name.includes('/') || name.includes('..')) return sendStatus(res, 404);
        const file = '/data/static/' + name;
        fs.stat(file, (err, st) => {
            if (err || !st.isFile()) return sendStatus(res, 404);
            res.writeHead(200, {
                'content-type': MIME[path_.extname(name)] || 'application/octet-stream',
                'content-length': st.size,
                'server': SERVER_HDR
            });
            const stream = fs.createReadStream(file);
            stream.on('error', () => res.destroy());
            stream.pipe(res);
        });
    }

    // ── database ────────────────────────────────────────────────────────────
    const EMPTY_ITEMS = '{"items":[],"count":0}';

    function queryValue(query, key) {
        for (let part = 0, i = 0; i <= query.length; i++) {
            if (i === query.length || query.charCodeAt(i) === 38 /* & */) {
                const pair = query.slice(part, i);
                const eq = pair.indexOf('=');
                if (eq > 0 && pair.slice(0, eq) === key) return pair.slice(eq + 1);
                part = i + 1;
            }
        }
        return null;
    }
    const intParam = (query, key, dflt) => {
        const n = parseInt(queryValue(query, key), 10);
        return n === n ? n : dflt;
    };

    async function asyncDb(res, query) {
        if (!pgPool) return sendJson(res, EMPTY_ITEMS);
        const min = intParam(query, 'min', 10), max = intParam(query, 'max', 50);
        let limit = intParam(query, 'limit', 50);
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            // Named, so pg prepares it once per connection and later executions
            // skip the parse; the parameterized form alone re-parses every call.
            const r = await pgPool.query({
                name: 'items-by-price',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
                values: [min, max, limit]
            });
            const items = r.rows.map(itemShape);
            sendJson(res, JSON.stringify({ items, count: items.length }));
        } catch { sendJson(res, EMPTY_ITEMS); }
    }

    async function crudList(res, query) {
        if (!pgPool) return dbError(res, 'DB not available');
        const category = queryValue(query, 'category') || 'electronics';
        const page = Math.max(1, intParam(query, 'page', 1));
        let limit = intParam(query, 'limit', 10);
        if (limit < 1) limit = 1;
        if (limit > 50) limit = 50;
        try {
            const r = await pgPool.query({
                name: 'crud-list',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3',
                values: [category, limit, (page - 1) * limit]
            });
            const items = r.rows.map(itemShape);
            sendJson(res, JSON.stringify({ items, total: items.length, page, limit }));
        } catch { dbError(res, 'query failed'); }
    }

    // Cache-aside on Redis where the harness provides it - crud is the one
    // profile that does, and it is shared across workers as a per-worker map
    // would not be.
    const CRUD_TTL_MS = 200;

    async function crudRead(res, id) {
        if (!pgPool) return dbError(res, 'DB not available');
        if (id !== id) return sendStatus(res, 404);
        try {
            if (redis) {
                const hit = await redis.get('crud:' + id);
                if (hit) return sendJson(res, hit, 200, { 'x-cache': 'HIT' });
            }
            const r = await pgPool.query({
                name: 'crud-read',
                text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE id = $1 LIMIT 1',
                values: [id]
            });
            if (r.rows.length === 0) return sendStatus(res, 404);
            const body = JSON.stringify(itemShape(r.rows[0]));
            if (redis) redis.set('crud:' + id, body, 'PX', CRUD_TTL_MS);
            sendJson(res, body, 200, { 'x-cache': 'MISS' });
        } catch { dbError(res, 'query failed'); }
    }

    function crudCreate(req, res) {
        if (!pgPool) return dbError(res, 'DB not available');
        readJson(req, async (b) => {
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
            } catch { dbError(res, 'insert failed'); }
        });
    }

    function crudUpdate(req, res, id) {
        if (!pgPool) return dbError(res, 'DB not available');
        if (id !== id) return sendStatus(res, 404);
        readJson(req, async (b) => {
            if (!b) return dbError(res, 'update failed');
            try {
                const r = await pgPool.query({
                    name: 'crud-update',
                    text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
                    values: [b.name ?? 'Updated', b.price ?? 0, b.quantity ?? 0, id]
                });
                if (r.rowCount === 0) return sendStatus(res, 404);
                if (redis) await redis.del('crud:' + id);
                sendJson(res, JSON.stringify({
                    id, name: b.name, price: b.price, quantity: b.quantity
                }));
            } catch { dbError(res, 'update failed'); }
        });
    }

    // ── fortunes ────────────────────────────────────────────────────────────
    // The escape is the profile's load-bearing check: row 11 of the seed carries
    // a <script> tag and it has to leave here as text.
    const RUNTIME_FORTUNE = 'Additional fortune added at request time.';
    const ESCAPE = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
    const escapeHtml = (s) => s.replace(/[&<>"']/g, c => ESCAPE[c]);

    async function fortunes(res) {
        if (!pgPool) { res.writeHead(500, { 'content-type': 'text/plain', 'server': SERVER_HDR }); return res.end('DB not available'); }
        try {
            const r = await pgPool.query({ name: 'fortunes', text: 'SELECT id, message FROM fortune' });
            const all = r.rows.map(x => ({ id: x.id, message: x.message }));
            all.push({ id: 0, message: RUNTIME_FORTUNE });
            // Ordinal, not locale aware: the seed carries em-dashes and collation
            // rules would order them in a way the profile does not ask for.
            all.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
            let body = '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>' +
                '<tr><th>id</th><th>message</th></tr>';
            for (const f of all) body += '<tr><td>' + f.id + '</td><td>' + escapeHtml(f.message) + '</td></tr>';
            body += '</table></body></html>';
            res.writeHead(200, {
                'content-type': 'text/html; charset=utf-8',
                'content-length': Buffer.byteLength(body),
                'server': SERVER_HDR
            });
            res.end(body);
        } catch {
            res.writeHead(500, { 'content-type': 'text/plain', 'server': SERVER_HDR });
            res.end('query failed');
        }
    }

    const handle = (req, res) => {
        // req.url is the request target, so the path is everything before the "?"
        const url = req.url;
        const mark = url.indexOf('?');
        const path = mark < 0 ? url : url.slice(0, mark);
        const query = mark < 0 ? '' : url.slice(mark + 1);

        if (path === '/pipeline') return sendText(res, 'ok');

        if (path === '/baseline11') {
            const querySum = sumQuery(query);
            if (req.method !== 'POST') return sendText(res, String(querySum));
            // Content-Length or chunked, node:http gives the same data events either way
            let body = '';
            req.setEncoding('utf8');
            req.on('data', chunk => body += chunk);
            req.on('end', () => {
                let total = querySum;
                const n = parseInt(body.trim(), 10);
                if (n === n) total += n;
                sendText(res, String(total));
            });
            return;
        }

        if (path.startsWith('/json/')) return json(req, res, path, query);

        if (path === '/upload' && req.method === 'POST') {
            // Counted chunk by chunk: the profile posts up to 20 MB per request over
            // hundreds of connections, and buffering the bodies would only cost memory
            let size = 0;
            req.on('data', chunk => size += chunk.length);
            req.on('end', () => sendText(res, String(size)));
            return;
        }

        if (path === '/baseline2') return sendText(res, String(sumQuery(query)));

        if (path.startsWith('/static/')) return serveStatic(res, path);

        if (path === '/async-db') return asyncDb(res, query);

        if (path === '/fortunes') return fortunes(res);

        if (path === '/crud/items') {
            if (req.method === 'POST') return crudCreate(req, res);
            return crudList(res, query);
        }
        if (path.startsWith('/crud/items/')) {
            const id = parseInt(path.slice(12), 10);
            if (req.method === 'PUT') return crudUpdate(req, res, id);
            return crudRead(res, id);
        }

        res.writeHead(404, { 'content-type': 'text/plain', 'content-length': 9, 'server': SERVER_HDR });
        res.end('Not found');
    };

    const server = http.createServer(handle);

    // Scaling is cluster to fork the workers, but not its round robin: with reusePort
    // every worker binds 8080 itself with SO_REUSEPORT and the kernel spreads the
    // accepts, the way bun and deno do it. node sets exclusive on its own when
    // reusePort is true, so the cluster listen path is out of the way.
    server.listen({ port: 8080, host: '0.0.0.0', reusePort: true });

    // json-tls and static-tls: the same routes over TLS on 8081. node's TLS stack
    // advertises no ALPN protocol here, so an HTTP/1.1 client negotiates plain
    // http/1.1 and never sees an h2 offer - which is what those two profiles ask
    // for. The harness only mounts /certs for the TLS profiles, so without them
    // this listener is simply not opened.
    try {
        const key = fs.readFileSync(process.env.TLS_KEY || '/certs/server.key');
        const cert = fs.readFileSync(process.env.TLS_CERT || '/certs/server.crt');
        https.createServer({ key, cert }, handle)
            .listen({ port: 8081, host: '0.0.0.0', reusePort: true });
    } catch {}
}
