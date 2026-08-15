// fulmine.js, an Express 5 drop-in on uWebSockets.js. This file is the whole server: it is read
// as documentation as much as it is run, so everything here is a documented option of the
// framework and nothing reaches around it.
//
// It runs once per process. express({ cluster: 'auto' }) forks one worker per usable core and
// each worker binds the same port with uWS's shared flag, SO_REUSEPORT, so the kernel spreads the
// connections and no primary sits in the path. The primary only forks and restarts a worker that
// dies: everything below runs in the workers.

// How many workers there are, which is what the Postgres pool below has to divide by. The
// framework counts the same way for 'auto': the cgroup quota first, the machine only when there
// is no quota to read.
function getCPUCount() {
    try {
        const max = require('fs').readFileSync('/sys/fs/cgroup/cpu.max', 'utf8').trim();
        const [quota, period] = max.split(' ');
        if (quota !== 'max') {
            const cgroup = Math.floor(Number(quota) / Number(period));
            if (cgroup >= 1) return cgroup;
        }
    } catch {}
    return require('os').availableParallelism();
}

const express = require('fulmine.js');
const fs = require('fs');
const zlib = require('zlib');

// The framework's own compression middleware, which negotiates br and gzip per request and
// takes the compression module's options. json-comp counts the bytes twice over,
// rps * (minBpr/myBpr)^2, so brotli is worth its extra microseconds where the client offers
// it: q3 is 12% smaller than gzip level 1 here. Mounted on the json route rather than on the
// app, because that is the only route the profiles ask to compress.
const compress = express.compression({
    level: 1,
    brotli: { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 } }
});

// 'auto' is one worker per usable core, and usable means the cgroup quota where there is one: a
// container with two cores does not fork sixty-four processes because the host has them.
const app = express({ cluster: 'auto' });
app.disable('x-powered-by');
// documented under Performance tips as the setting for an API whose responses are never
// revalidated, which is every profile here: nothing sends a conditional request
app.set('etag', false);
// the static rules want every request to reach the disk, so the small-file cache is off
app.set('file cache', false);

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

// what the two body-carrying crud verbs read with. The error handler at the bottom turns the
// 400 it raises on a bad body into the empty answer the profile expects
const readJson = express.json();

function sumQuery(query) {
    let sum = 0;
    for (const k in query) {
        const n = parseInt(query[k], 10);
        if (n === n) sum += n;
    }
    return sum;
}

// Written out rather than through SERVER_HDR, and that is the whole of it: with every argument a
// literal, the framework compiles this handler into a uWS declarative response at listen() and the
// route is answered without entering JavaScript. A closure it cannot read keeps it on the ordinary
// path, which is what SERVER_HDR was doing here.
app.get('/pipeline', (req, res) => {
    res.set({ 'server': 'fulmine' }).type('text/plain').send('ok');
});

// shared by the plaintext listener and the TLS one on 8081: same handler, same shapes
const registerJsonRoute = (target, path = '/json/:count') => target.get(path, compress, (req, res) => {
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
        // the middleware compresses this when the request asked for it, and leaves it alone
        // when it did not: the json profile sends no Accept-Encoding, json-comp sends one
        //
        // res.json and not type().send(JSON.stringify()): it writes the content-type straight
        // into the header object instead of going through set(), which costs a lowercase, a
        // charset regex and a validation. Same bytes on the wire, 0.9 to 1.2 us less per response
        res.set(SERVER_HDR).json({ items, count });
    } else {
        res.status(500).send('No dataset');
    }
});
registerJsonRoute(app);

// fortunes is the one profile here that measures a template engine, so it goes through
// res.render and a real EJS template rather than the string building the tuned rules would
// also allow: rendering it by hand would measure something the profile is not asking about.
app.set('views', __dirname + '/views');
app.set('view engine', 'ejs');
const RUNTIME_FORTUNE = 'Additional fortune added at request time.';

app.get('/fortunes', async (req, res) => {
    if (!pgPool) return res.status(500).set(SERVER_HDR).type('text/plain').send('DB not available');
    try {
        const result = await pgPool.query({ name: 'fortunes', text: 'SELECT id, message FROM fortune' });
        const rows = result.rows.map(r => ({ id: r.id, message: r.message }));
        rows.push({ id: 0, message: RUNTIME_FORTUNE });
        // ordinal, not locale aware: the synthetic rows carry em-dashes, and localeCompare
        // would order them by collation rules the profile does not ask for
        rows.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
        res.set(SERVER_HDR).render('fortunes', { fortunes: rows });
    } catch (e) {
        res.status(500).set(SERVER_HDR).type('text/plain').send('query failed');
    }
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

// the cache-aside read, registered under /crud for the crud profile and under /api for
// production-stack, which asks for the same thing behind the edge's JWT check
const itemRead = async (req, res) => {
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
};
app.get('/crud/items/:id', itemRead);

app.post('/crud/items', readJson, async (req, res) => {
    if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
    const body = req.body;
    try {
        const result = await pgPool.query({
            name: 'crud-create',
            text: 'INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) ' +
                "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
                'ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id',
            values: [body.id, body.name ?? 'New Product', body.category ?? 'test', body.price ?? 0, body.quantity ?? 0]
        });
        res.status(201).set(SERVER_HDR).json({
            id: result.rows[0].id, name: body.name, category: body.category,
            price: body.price, quantity: body.quantity
        });
    } catch (e) {
        res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"insert failed"}');
    }
});

app.put('/crud/items/:id', readJson, async (req, res) => {
    if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
    const id = parseInt(req.params.id, 10);
    if (!Number.isFinite(id)) return res.status(404).set(SERVER_HDR).end();
    const body = req.body;
    try {
        const result = await pgPool.query({
            name: 'crud-update',
            text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
            values: [body.name ?? 'Updated', body.price ?? 0, body.quantity ?? 0, id]
        });
        if (result.rowCount === 0) return res.status(404).set(SERVER_HDR).end();
        await crudDel(id);
        res.set(SERVER_HDR).json({
            id, name: body.name, price: body.price, quantity: body.quantity
        });
    } catch (e) {
        res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"update failed"}');
    }
});

// ── production-stack ──────────────────────────────────────────────────
// Four services, and this is the server behind them. The edge terminates TLS, serves
// /static/* itself and sends /api/* past the shared JWT verifier first, so nothing here
// checks a token: what arrives is already authorised and carries X-User-Id.
const USER_TTL_MS = 30000;
const userGet = (id) => {
    if (redis) return redis.get('user:' + id);
    const hit = crudCache.get('user:' + id);
    if (!hit) return null;
    if (hit.until <= Date.now()) { crudCache.delete('user:' + id); return null; }
    return hit.json;
};
const userSet = (id, json) => {
    if (redis) return redis.set('user:' + id, json, 'PX', USER_TTL_MS);
    crudCache.set('user:' + id, { json, until: Date.now() + USER_TTL_MS });
};

app.get('/public/baseline', (req, res) => {
    res.set(SERVER_HDR).type('text/plain').send(String(sumQuery(req.query)));
});
registerJsonRoute(app, '/public/json/:count');
app.get('/api/items/:id', itemRead);

// 204 and no body, unlike the crud PUT this otherwise mirrors. The cache entry goes after
// the row is written, so the next read misses and repopulates from Postgres.
app.post('/api/items/:id', readJson, async (req, res) => {
    if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
    const id = parseInt(req.params.id, 10);
    if (!Number.isFinite(id)) return res.status(404).set(SERVER_HDR).end();
    const body = req.body;
    try {
        const result = await pgPool.query({
            name: 'crud-update',
            text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
            values: [body.name ?? 'Updated', body.price ?? 0, body.quantity ?? 0, id]
        });
        if (result.rowCount === 0) return res.status(404).set(SERVER_HDR).end();
        await crudDel(id);
        res.status(204).set(SERVER_HDR).end();
    } catch (e) {
        res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"update failed"}');
    }
});

app.get('/api/me', async (req, res) => {
    if (!pgPool) return res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"DB not available"}');
    const id = parseInt(req.headers['x-user-id'], 10);
    if (!Number.isFinite(id)) return res.status(401).set(SERVER_HDR).end();
    try {
        const cached = await userGet(id);
        if (cached) {
            return res.set(CACHE_HIT_HDR).type('application/json').send(cached);
        }
        const result = await pgPool.query({
            name: 'user-read',
            text: 'SELECT id, name, email, plan FROM users WHERE id = $1 LIMIT 1',
            values: [id]
        });
        if (result.rows.length === 0) return res.status(404).set(SERVER_HDR).end();
        const u = result.rows[0];
        const json = JSON.stringify({ id: u.id, name: u.name, email: u.email, plan: u.plan });
        userSet(id, json);
        res.set(CACHE_MISS_HDR).type('application/json').send(json);
    } catch (e) {
        res.status(500).set(SERVER_HDR).type('application/json').send('{"error":"query failed"}');
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

// shared by the plaintext listener and the TLS one on 8081, as the JSON route is: static-tls
// asks for the same files over TLS.
//
// preCompressed is the framework's documented way of serving the .br and .gz files the harness
// leaves on disk next to the originals: the middleware negotiates between them, keeps the
// content type of the name that was asked for and gives each variant its own ETag. Nothing is
// held in memory, and with "file cache" off every request reads the file it answers with.
const registerStaticRoute = (target) =>
    target.use(
        '/static',
        express.static('/data/static', {
            preCompressed: true,
            index: false,
            fallthrough: false,
            setHeaders: (res) => res.setHeader('server', 'fulmine')
        })
    );
registerStaticRoute(app);

// What express.json() raises on a body that will not parse, and what express.static raises for
// a file that is not there: both carry the status the profile expects, and neither wants the
// framework's error page in the body
const answerError = (err, req, res, next) => {
    if (res.headersSent) return next(err);
    res.status(err.status || err.statusCode || 500).set(SERVER_HDR).end();
};
app.use(answerError);

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
    tlsApp.set('file cache', false);
    registerJsonRoute(tlsApp);
    registerStaticRoute(tlsApp);
    tlsApp.use(answerError);
    tlsApp.listen(8081);
}

app.listen(8080);
