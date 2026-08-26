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

// The framework's own compression middleware, mounted on the json route rather than on the app,
// because that is the only route the profiles ask to compress.
//
// gzip and not brotli, which is a reversal, and it is 5.18.0 that reverses it: a whole body is
// now gzipped on a stream the framework keeps rather than on one built and thrown away per call,
// which is half of what the call used to cost at this size. A brotli stream cannot be kept that
// way, it carries context from one body into the next, so it still pays the build every time.
// json-comp scores rps * (minBpr/myBpr)^2, so brotli's 10% smaller body is worth roughly a fifth
// of the score and the cheaper call is worth more than that. `encodings` is the documented way to
// say it: the client offers both and gets gzip.
//
// Level 3 rather than 1: once the per-call build is gone, levels 1, 2 and 3 cost the same, and 3
// is the smallest of them.
const compress = express.compression({ level: 3, encodings: ['gzip'] });

// 'auto' is one worker per usable core, and usable means the cgroup quota where there is one: a
// container with two cores does not fork sixty-four processes because the host has them.
const app = express({ cluster: 'auto' });
app.disable('x-powered-by');
// documented under Performance tips as the setting for an API whose responses are never
// revalidated, which is every profile here: nothing sends a conditional request
app.set('etag', false);
// What this entry tunes is one line below and the Postgres driver further down, both through
// documented options of the framework.
//
// The body cache is the framework's and is on by default, here as in the standard entry.
//
// The stat cache that used to be on this line is gone. It remembered size and mtime for a
// window, and a body cache validated against a remembered stat cannot see a file that was
// replaced inside it, which is the one thing the static rules ask of a cache. Measured against
// the validator's own staleness probe: the two together fail it, the body cache alone passes.
app.set('file cache', true);
// Connection: keep-alive and Keep-Alive: timeout=10 on every response, which is what express
// sends and what the standard entry therefore sends too. HTTP/1.1 keeps the connection alive
// without being told, so the bytes buy nothing here
app.set('connection headers', false);

// built once and not per response: the crud read path is the busiest route this entry has
const CACHE_HIT_HDR = { 'x-cache': 'HIT' };
const CACHE_MISS_HDR = { 'x-cache': 'MISS' };

// Dataset
let datasetItems;
try {
    datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
} catch (e) {}

// PostgreSQL. Per-worker pool sized so workers x perWorker stays under Postgres
// max_connections (256 default, 240 leaves a reserve): a flat 4 per worker saturated the
// server on a 64-core runner and every request paid the contention.
let pgPool;
let sql;
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
        // pg-telaio pipelines the queries on perWorker connections of its own instead of one
        // checkout per query, which measured 1.3x to 3x on the point reads at this budget.
        // The pool is kept to one connection, the tag's overflow for a stalled pipeline, so
        // the connection budget stays perWorker + 1.
        const pool = new Pool({ connectionString: dbUrl, max: 1 });
        // stallMillis false turns off the tag's slow-query guard, which parks a connection that
        // has stopped answering and sends its queries to the pool. Every query these profiles
        // run is a point read of a few milliseconds, so the guard can only cost here: measured
        // 5% to 12% at this shape. It stays on by default for a mixed workload, where one slow
        // query would otherwise hold up the fast ones queued behind it.
        sql = require('pg-telaio').createSql(pool, { pipeline: perWorker, stallMillis: false });
        pgPool = pool;
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

// Every argument is a literal, and that is the whole of it: the framework compiles this handler
// into a uWS declarative response at listen() and the route is answered without entering
// JavaScript. A closure it cannot read would keep it on the ordinary path.
app.get('/pipeline', (req, res) => {
    res.type('text/plain').send('ok');
});

// GET /delay/{ms} — answered once ms milliseconds have gone by. setTimeout hands the request
// back to the event loop, so a request that is waiting costs one timer entry and the worker
// stays free for the next one: at 64K held connections that is 64K timers rather than 64K
// blocked threads.
//
// The value is read out of the path before the timer is armed, which is what this profile is
// really testing. µWS invalidates the request object the moment the handler returns, so a
// handler that reached for the parameter inside the callback would find it gone; keeping it in
// the closure also gives every overlapping request its own delay, which is what the 32-way
// concurrent probe looks for.
app.get('/delay/:ms', (req, res) => {
    const ms = parseInt(req.params.ms, 10) || 0;
    setTimeout(() => {
        res.type('text/plain').send(String(ms));
    }, ms);
});

// shared by the plaintext listener and the TLS one on 8081: same handler, same shapes
const registerJsonRoute = (target, path = '/json/:count') => target.get(path, compress, (req, res) => {
    if (datasetItems) {
        let count = parseInt(req.params.count, 10) || 0;
        if (count < 0) count = 0;
        if (count > datasetItems.length) count = datasetItems.length;
        const m = parseInt(req.query.m) || 1;
        // a preallocated loop, not slice().map(): same items, without the sliced
        // copy and the per-element callback
        const items = new Array(count);
        for (let i = 0; i < count; i++) {
            const d = datasetItems[i];
            items[i] = {
                id: d.id, name: d.name, category: d.category,
                price: d.price, quantity: d.quantity, active: d.active,
                tags: d.tags, rating: d.rating,
                total: d.price * d.quantity * m
            };
        }
        // the middleware compresses this when the request asked for it, and leaves it alone
        // when it did not: the json profile sends no Accept-Encoding, json-comp sends one
        //
        // res.json and not type().send(JSON.stringify()): it writes the content-type straight
        // into the header object instead of going through set(), which costs a lowercase, a
        // charset regex and a validation. Same bytes on the wire, 0.9 to 1.2 us less per response
        res.json({ items, count });
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
    if (!pgPool) return res.status(500).type('text/plain').send('DB not available');
    try {
        const result = await sql`SELECT id, message FROM fortune`;
        // the driver rows already carry only id and message, so the runtime row is
        // pushed onto them and they are sorted in place instead of copied first
        const rows = result.rows;
        rows.push({ id: 0, message: RUNTIME_FORTUNE });
        // ordinal, not locale aware: the synthetic rows carry em-dashes, and localeCompare
        // would order them by collation rules the profile does not ask for
        rows.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
        res.render('fortunes', { fortunes: rows });
    } catch (e) {
        res.status(500).type('text/plain').send('query failed');
    }
});

app.get('/async-db', async (req, res) => {
    if (!pgPool) {
        return res.type('application/json').send('{"items":[],"count":0}');
    }
    const min = parseInt(req.query.min, 10) || 10;
    const max = parseInt(req.query.max, 10) || 50;
    let limit = parseInt(req.query.limit, 10) || 50;
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;
    try {
        // the tag turns the values into parameters, names and prepares the statement by
        // itself, and pipelines the round trip on its shared connections
        const result =
            await sql`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ${min} AND ${max} LIMIT ${limit}`;
        const items = result.rows.map(r => ({
            id: r.id, name: r.name, category: r.category,
            price: r.price, quantity: r.quantity, active: r.active,
            tags: r.tags,
            rating: { score: r.rating_score, count: r.rating_count }
        }));
        const body = JSON.stringify({ items, count: items.length });
        res.type('application/json').send(body);
    } catch (e) {
        res.type('application/json').send('{"items":[],"count":0}');
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
    if (!pgPool) return res.status(500).type('application/json').send('{"error":"DB not available"}');
    const category = String(req.query.category || 'electronics');
    const page = Math.max(1, parseInt(req.query.page, 10) || 1);
    let limit = parseInt(req.query.limit, 10) || 10;
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;
    try {
        const result =
            await sql`SELECT ${sql.unsafe(ITEM_COLUMNS)} FROM items WHERE category = ${category} ORDER BY id LIMIT ${limit} OFFSET ${(page - 1) * limit}`;
        const items = result.rows.map(itemShape);
        res.type('application/json')
            .send(JSON.stringify({ items, total: items.length, page, limit }));
    } catch (e) {
        res.status(500).type('application/json').send('{"error":"query failed"}');
    }
});

// the cache-aside read, registered under /crud for the crud profile and under /api for
// production-stack, which asks for the same thing behind the edge's JWT check
const itemRead = async (req, res) => {
    if (!pgPool) return res.status(500).type('application/json').send('{"error":"DB not available"}');
    const id = parseInt(req.params.id, 10);
    if (!Number.isFinite(id)) return res.status(404).end();
    try {
        const cached = await crudGet(id);
        if (cached) {
            return res.set(CACHE_HIT_HDR).type('application/json').send(cached);
        }
        const result = await sql`SELECT ${sql.unsafe(ITEM_COLUMNS)} FROM items WHERE id = ${id} LIMIT 1`;
        if (result.rows.length === 0) return res.status(404).end();
        const json = JSON.stringify(itemShape(result.rows[0]));
        crudSet(id, json);
        res.set(CACHE_MISS_HDR).type('application/json').send(json);
    } catch (e) {
        res.status(500).type('application/json').send('{"error":"query failed"}');
    }
};
app.get('/crud/items/:id', itemRead);

app.post('/crud/items', readJson, async (req, res) => {
    if (!pgPool) return res.status(500).type('application/json').send('{"error":"DB not available"}');
    const body = req.body;
    try {
        // excluded.* instead of the old $n back references: a template cannot repeat a
        // positional parameter, and excluded says the same thing in SQL
        const result =
            await sql`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (${body.id}, ${body.name ?? 'New Product'}, ${body.category ?? 'test'}, ${body.price ?? 0}, ${body.quantity ?? 0}, true, '["bench"]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = excluded.name, price = excluded.price, quantity = excluded.quantity RETURNING id`;
        res.status(201).json({
            id: result.rows[0].id, name: body.name, category: body.category,
            price: body.price, quantity: body.quantity
        });
    } catch (e) {
        res.status(500).type('application/json').send('{"error":"insert failed"}');
    }
});

app.put('/crud/items/:id', readJson, async (req, res) => {
    if (!pgPool) return res.status(500).type('application/json').send('{"error":"DB not available"}');
    const id = parseInt(req.params.id, 10);
    if (!Number.isFinite(id)) return res.status(404).end();
    const body = req.body;
    try {
        const result =
            await sql`UPDATE items SET name = ${body.name ?? 'Updated'}, price = ${body.price ?? 0}, quantity = ${body.quantity ?? 0} WHERE id = ${id}`;
        if (result.rowCount === 0) return res.status(404).end();
        await crudDel(id);
        res.json({
            id, name: body.name, price: body.price, quantity: body.quantity
        });
    } catch (e) {
        res.status(500).type('application/json').send('{"error":"update failed"}');
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
    res.type('text/plain').send(String(sumQuery(req.query)));
});
registerJsonRoute(app, '/public/json/:count');
app.get('/api/items/:id', itemRead);

// 204 and no body, unlike the crud PUT this otherwise mirrors. The cache entry goes after
// the row is written, so the next read misses and repopulates from Postgres.
app.post('/api/items/:id', readJson, async (req, res) => {
    if (!pgPool) return res.status(500).type('application/json').send('{"error":"DB not available"}');
    const id = parseInt(req.params.id, 10);
    if (!Number.isFinite(id)) return res.status(404).end();
    const body = req.body;
    try {
        const result =
            await sql`UPDATE items SET name = ${body.name ?? 'Updated'}, price = ${body.price ?? 0}, quantity = ${body.quantity ?? 0} WHERE id = ${id}`;
        if (result.rowCount === 0) return res.status(404).end();
        await crudDel(id);
        res.status(204).end();
    } catch (e) {
        res.status(500).type('application/json').send('{"error":"update failed"}');
    }
});

app.get('/api/me', async (req, res) => {
    if (!pgPool) return res.status(500).type('application/json').send('{"error":"DB not available"}');
    const id = parseInt(req.headers['x-user-id'], 10);
    if (!Number.isFinite(id)) return res.status(401).end();
    try {
        const cached = await userGet(id);
        if (cached) {
            return res.set(CACHE_HIT_HDR).type('application/json').send(cached);
        }
        const result = await sql`SELECT id, name, email, plan FROM users WHERE id = ${id} LIMIT 1`;
        if (result.rows.length === 0) return res.status(404).end();
        const u = result.rows[0];
        const json = JSON.stringify({ id: u.id, name: u.name, email: u.email, plan: u.plan });
        userSet(id, json);
        res.set(CACHE_MISS_HDR).type('application/json').send(json);
    } catch (e) {
        res.status(500).type('application/json').send('{"error":"query failed"}');
    }
});

app.post('/upload', (req, res) => {
    let size = 0;
    req.on('data', chunk => size += chunk.length);
    req.on('end', () => {
        res.type('text/plain').send(String(size));
    });
});

app.get('/baseline2', (req, res) => {
    res.type('text/plain').send(String(sumQuery(req.query)));
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
            res.type('text/plain').send(String(total));
        });
    } else {
        res.type('text/plain').send(String(querySum));
    }
});

// shared by the plaintext listener and the TLS one on 8081, as the JSON route is: static-tls
// asks for the same files over TLS.
//
// preCompressed is the framework's documented way of serving the .br and .gz files the harness
// leaves on disk next to the originals: the middleware negotiates between them, keeps the
// content type of the name that was asked for and gives each variant its own ETag. This is the
// same static route the standard entry serves, with the same cache: nothing here is tuned.
const registerStaticRoute = (target) =>
    target.use(
        '/static',
        express.static('/data/static', {
            preCompressed: true,
            index: false,
            fallthrough: false
        })
    );
registerStaticRoute(app);

// What express.json() raises on a body that will not parse, and what express.static raises for
// a file that is not there: both carry the status the profile expects, and neither wants the
// framework's error page in the body
const answerError = (err, req, res, next) => {
    if (res.headersSent) return next(err);
    res.status(err.status || err.statusCode || 500).end();
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
    // the same as the plaintext app above, so static-tls is served the same way
    tlsApp.set('file cache', true);
    tlsApp.set('connection headers', false);
    registerJsonRoute(tlsApp);
    registerStaticRoute(tlsApp);
    tlsApp.use(answerError);
    tlsApp.listen(8081);
}

// tls_check: the opt-in TLS hardening section, on a listener of its own on 9000 reading a
// certificate directory of its own. The section replaces the pair under the running server, and
// /certs-tls exists so that doing so cannot move the ground under json-tls, static-tls and the h2
// profiles, which read /certs and run in the same validation.
//
// Only validate.sh mounts the directory, so on a measured run this block does not exist: no
// second listener is built and nothing is stat'd.
if (fs.existsSync('/certs-tls/server.key') && fs.existsSync('/certs-tls/server.crt')) {
    // What a rotation costs here is a listener rather than a handshake. µWS reads the pair once,
    // when the SSL context is built, and nothing points an existing context at a new file
    // afterwards: addServerName() replaces the certificate for one SNI name and leaves the
    // default context -- which is what answers a client that sends no server name -- on the old
    // one. Measured both ways: after addServerName('localhost', ...) an -servername handshake is
    // served the new certificate and a -noservername handshake is still served the old. Building
    // the listener again is the rotation that reaches both.
    //
    // And it interrupts nothing, because a worker binds the port shared -- SO_REUSEPORT -- so the
    // replacement can be accepting on 9000 beside the listener it replaces before that one is
    // told to stop. close() then closes the old listen socket, lets what it is already serving
    // finish, and drops its idle keep-alives only after that: nothing is refused and no response
    // is cut short.
    const buildTlsCheckApp = () => {
        const tlsCheckApp = express({
            uwsOptions: {
                key_file_name: '/certs-tls/server.key',
                cert_file_name: '/certs-tls/server.crt'
            }
        });
        tlsCheckApp.disable('x-powered-by');
        tlsCheckApp.set('etag', false);
        tlsCheckApp.set('file cache', true);
        tlsCheckApp.set('connection headers', false);
        registerJsonRoute(tlsCheckApp);
        registerStaticRoute(tlsCheckApp);
        tlsCheckApp.use(answerError);
        return tlsCheckApp;
    };

    // What counts as a new pair. The section swaps both files with mv, so the inode moves along
    // with the mtime, and the size is in here because a pair regenerated inside the same
    // millisecond would otherwise read as unchanged.
    const pairStamp = () => {
        try {
            const key = fs.statSync('/certs-tls/server.key');
            const crt = fs.statSync('/certs-tls/server.crt');
            return key.ino + ':' + key.size + ':' + key.mtimeMs + '|' + crt.ino + ':' + crt.size + ':' + crt.mtimeMs;
        } catch (e) {
            // mid-swap a file is missing for an instant. Reporting no reading rather than a new
            // one picks the rotation up on the next tick instead of building a context out of
            // half of one pair and half of the other
            return '';
        }
    };

    let live = buildTlsCheckApp();
    let stamp = pairStamp();

    const rotate = () => {
        const next = buildTlsCheckApp();
        const previous = live;
        next.listen(9000, (err) => {
            // the listener already up is still serving, so it is the right thing to keep when
            // the replacement cannot bind
            if (err) return;
            live = next;
            previous.close();
        });
    };

    live.listen(9000, (err) => {
        if (err) return;
        // Armed from inside the listen callback because that is what says this process owns a
        // listener: the primary of a clustered app returns from listen() without binding
        // anything, so only the workers arrive here and only they have a certificate to rotate.
        // One second is the reference entry's interval and is two orders off the 30s the section
        // allows, and the stat is only paid while the section is mounted.
        setInterval(() => {
            const now = pairStamp();
            if (now && now !== stamp) {
                stamp = now;
                rotate();
            }
        }, 1000).unref();
    });
}

app.listen(8080);
