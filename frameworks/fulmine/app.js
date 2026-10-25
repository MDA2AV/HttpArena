// fulmine.js, an Express 5 drop-in on uWebSockets.js. Every option used here is documented:
// https://fulmine.sndesign.it/performance#performance-tips
const fs = require('fs');
const zlib = require('zlib');
const express = require('fulmine.js');

// One worker per usable core (cgroup quota first), all on the same port with SO_REUSEPORT.
// https://fulmine.sndesign.it/examples/cluster
const app = express({ cluster: 'auto' });

// No profile sends a conditional request, and every client keeps the connection open.
const configure = (target) => {
    target.disable('x-powered-by');
    target.set('etag', false);
    target.set('connection headers', false);
    return target;
};
configure(app);

// Each worker opens its own pool, app.cluster.share() splits the connections between them.
// Postgres allows DATABASE_MAX_CONN, 240 at most leaves a reserve.
// https://fulmine.sndesign.it/examples/cluster-pool
const connections = Math.min(parseInt(process.env.DATABASE_MAX_CONN, 10) || 256, 240);
// pg and ioredis load on first use: only the database and production-stack profiles need them,
// and loaded up front they kept every worker over the heap size where V8 starts full collections
let pool = null;
const db = () =>
    (pool ??= new (require('pg').native.Pool)({ connectionString: process.env.DATABASE_URL, max: app.cluster.share(connections) }));

const dataset = JSON.parse(fs.readFileSync('/data/dataset.json', 'utf8'));

// Brotli quality 3: 9% fewer bytes than gzip level 3 on json-comp, and the encoder is reused.
// https://fulmine.sndesign.it/examples/compression
const compress = express.compression({
    encodings: ['br'],
    brotli: { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 } },
});

const readText = express.text({ type: () => true });
const readRaw = express.raw({ type: () => true, limit: '1mb' });
const readJson = express.json();

function sumQuery(query) {
    let sum = 0;
    for (const k in query) {
        const n = parseInt(query[k], 10);
        if (n === n) sum += n;
    }
    return sum;
}

const itemShape = (r) => ({
    id: r.id, name: r.name, category: r.category,
    price: r.price, quantity: r.quantity, active: r.active,
    tags: r.tags,
    rating: { score: r.rating_score, count: r.rating_count }
});
const ITEM_COLUMNS = 'id, name, category, price, quantity, active, tags, rating_score, rating_count';

// Only literals, so listen() compiles it to a uWS declarative response.
// https://fulmine.sndesign.it/examples/fast-routes
app.get('/pipeline', (req, res) => {
    res.type('text/plain').send('ok');
});

// GET and POST registered apart: each one goes native on uWS, and the GET reads no header.
app.get('/baseline11', (req, res) => {
    res.type('text/plain').send(String(sumQuery(req.query)));
});

// the load generator sends no Content-Type, so the parser reads any body
app.post('/baseline11', readText, (req, res) => {
    let total = sumQuery(req.query);
    const n = parseInt(typeof req.body === 'string' ? req.body.trim() : '', 10);
    if (n === n) total += n;
    res.type('text/plain').send(String(total));
});

app.get('/baseline2', (req, res) => {
    res.type('text/plain').send(String(sumQuery(req.query)));
});

app.get('/delay/:ms', (req, res) => {
    const ms = parseInt(req.params.ms, 10) || 0;
    setTimeout(() => res.type('text/plain').send(String(ms)), ms);
});

const registerJsonRoute = (target, path = '/json/:count') => target.get(path, compress, (req, res) => {
    const count = Math.min(Math.max(parseInt(req.params.count, 10) || 0, 0), dataset.length);
    const m = parseInt(req.query.m, 10) || 1;
    const items = new Array(count);
    for (let i = 0; i < count; i++) {
        const d = dataset[i];
        items[i] = {
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m
        };
    }
    res.json({ items, count });
});

const registerEchoRoute = (target) => target.post('/echo', readRaw, (req, res) => {
    // an empty body leaves req.body unset
    res.type('application/octet-stream').send(Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0));
});

// The .br and .gz files on disk are served when the client accepts them.
// https://fulmine.sndesign.it/examples/static-precompressed
const registerStaticRoute = (target) => target.use('/static', express.static('/data/static', {
    preCompressed: true,
    index: false,
    fallthrough: false
}));

registerJsonRoute(app);
registerEchoRoute(app);
registerStaticRoute(app);

// A rejected promise goes to the framework's final handler, which answers 500, as on Express 5.
app.get('/async-db', async (req, res) => {
    const min = parseInt(req.query.min, 10) || 10;
    const max = parseInt(req.query.max, 10) || 50;
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 50, 1), 50);
    // named, so pg prepares it once per connection
    const { rows } = await db().query({
        name: 'items-by-price',
        text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
        values: [min, max, limit]
    });
    const items = rows.map(itemShape);
    res.json({ items, count: items.length });
});

app.set('views', __dirname + '/views');
app.set('view engine', 'ejs');

app.get('/fortunes', async (req, res) => {
    const { rows } = await db().query({ name: 'fortunes', text: 'SELECT id, message FROM fortune' });
    rows.push({ id: 0, message: 'Additional fortune added at request time.' });
    // ordinal and not localeCompare: the rows carry em-dashes
    rows.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
    res.render('fortunes', { fortunes: rows });
});

// production-stack: the edge checks the JWT and serves /static, Redis is the cache. Registered in
// every profile, as validate.sh keeps the plain container on the shared port during the stack, and
// lazyConnect opens no connection until a request needs one.
{
    let redis = null;
    const cache = () => {
        if (redis === null) {
            const Redis = require('ioredis');
            redis = new Redis(process.env.REDIS_URL || 'redis://127.0.0.1:6379', { enableAutoPipelining: true, lazyConnect: true });
            redis.on('error', () => {});
        }
        return redis;
    };
    const CACHE_HIT = { 'x-cache': 'HIT' };
    const CACHE_MISS = { 'x-cache': 'MISS' };

    app.get('/public/baseline', (req, res) => {
        res.type('text/plain').send(String(sumQuery(req.query)));
    });
    registerJsonRoute(app, '/public/json/:count');

    app.get('/api/items/:id', async (req, res) => {
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(404).end();
        const cached = await cache().get('crud:' + id);
        if (cached) return res.set(CACHE_HIT).type('application/json').send(cached);
        const { rows } = await db().query({
            name: 'crud-read',
            text: 'SELECT ' + ITEM_COLUMNS + ' FROM items WHERE id = $1 LIMIT 1',
            values: [id]
        });
        if (rows.length === 0) return res.status(404).end();
        const json = JSON.stringify(itemShape(rows[0]));
        cache().set('crud:' + id, json, 'PX', 200);
        res.set(CACHE_MISS).type('application/json').send(json);
    });

    // the cache entry goes after the row is written, so the next read takes the new one
    app.post('/api/items/:id', readJson, async (req, res) => {
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(404).end();
        const body = req.body;
        const { rowCount } = await db().query({
            name: 'crud-update',
            text: 'UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4',
            values: [body.name ?? 'Updated', body.price ?? 0, body.quantity ?? 0, id]
        });
        if (rowCount === 0) return res.status(404).end();
        await cache().del('crud:' + id);
        res.status(204).end();
    });

    app.get('/api/me', async (req, res) => {
        const id = parseInt(req.headers['x-user-id'], 10);
        if (!Number.isFinite(id)) return res.status(401).end();
        const cached = await cache().get('user:' + id);
        if (cached) return res.set(CACHE_HIT).type('application/json').send(cached);
        const { rows } = await db().query({
            name: 'user-read',
            text: 'SELECT id, name, email, plan FROM users WHERE id = $1 LIMIT 1',
            values: [id]
        });
        if (rows.length === 0) return res.status(404).end();
        const json = JSON.stringify(rows[0]);
        cache().set('user:' + id, json, 'PX', 30000);
        res.set(CACHE_MISS).type('application/json').send(json);
    });
}

// No error middleware on purpose: one anywhere in the app takes the fast paths off every route,
// and the final handler already answers 400, 404 and 413 with the status the profiles expect.

// app.uwsApp.ws and not app.ws: the echo needs no Request object on the upgrade.
// https://fulmine.sndesign.it/websockets
app.uwsApp.ws('/ws', {
    maxPayloadLength: 16 * 1024,
    message: (ws, message, isBinary) => ws.send(message, isBinary)
});

// json-tls, static-tls and 8gbit over TLS on 8081, when the harness mounts the certs.
// https://fulmine.sndesign.it/examples/https
const tlsApp = (dir) => {
    const target = configure(express({
        uwsOptions: { key_file_name: dir + '/server.key', cert_file_name: dir + '/server.crt' }
    }));
    registerJsonRoute(target);
    registerStaticRoute(target);
    registerEchoRoute(target);
    return target;
};
const hasPair = (dir) => fs.existsSync(dir + '/server.key') && fs.existsSync(dir + '/server.crt');

if (hasPair('/certs')) tlsApp('/certs').listen(8081);

// tls_check, mounted only by validate.sh. uWS reads the pair once per SSL context, so a rotation
// is a new listener on the shared port, then close() on the old one, which drains it.
if (hasPair('/certs-tls')) {
    const pairStamp = () => {
        try {
            const key = fs.statSync('/certs-tls/server.key');
            const crt = fs.statSync('/certs-tls/server.crt');
            return [key.ino, key.size, key.mtimeMs, crt.ino, crt.size, crt.mtimeMs].join(':');
        } catch {
            // mid-swap a file is missing for a moment, the next tick sees the whole pair
            return '';
        }
    };
    let live = tlsApp('/certs-tls');
    let stamp = pairStamp();
    live.listen(9000, (err) => {
        // only a worker arrives here: the primary of a clustered app binds nothing
        if (err) return;
        setInterval(() => {
            const now = pairStamp();
            if (!now || now === stamp) return;
            stamp = now;
            const next = tlsApp('/certs-tls');
            next.listen(9000, (e) => {
                if (e) return;
                live.close();
                live = next;
            });
        }, 1000).unref();
    });
}

app.listen(8080);
