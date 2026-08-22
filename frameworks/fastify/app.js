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
    start();
}

// Fastify binds one instance to one server, so the TLS listener needs its own
// instance. build() is the single definition of the app — both ports register
// the identical plugins and routes from it, rather than a hand-copied subset.
async function build(serverOpts) {
    const fastify = require('fastify')({ logger: false, ...serverOpts });
    const fs = require('fs');
    const Database = require('better-sqlite3');

    // standard mode: compression and static files go through the official plugins with their
    // default settings, nothing hand-rolled. Awaited, since a plugin registered without await
    // only attaches its onRoute hook after the routes below would already exist
    await fastify.register(require('@fastify/compress'));
    await fastify.register(require('@fastify/static'), { root: '/data/static', prefix: '/static/' });

    // the two POST endpoints read the raw stream themselves, so every content type hands the
    // payload through untouched instead of going to a body parser
    fastify.removeAllContentTypeParsers();
    fastify.addContentTypeParser('*', function (request, payload, done) {
        done(null, payload);
    });

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

    fastify.get('/pipeline', (request, reply) => {
        reply.header('server', 'fastify').type('text/plain').send('ok');
    });

    fastify.get('/json/:count', (request, reply) => {
        if (datasetItems) {
            let count = parseInt(request.params.count, 10) || 0;
            if (count < 0) count = 0;
            if (count > datasetItems.length) count = datasetItems.length;
            const m = parseInt(request.query.m) || 1;
            const items = datasetItems.slice(0, count).map(d => ({
                id: d.id, name: d.name, category: d.category,
                price: d.price, quantity: d.quantity, active: d.active,
                tags: d.tags, rating: d.rating,
                total: d.price * d.quantity * m
            }));
            const body = JSON.stringify({ items, count });
            // json-comp negotiation belongs to @fastify/compress, registered above
            reply.header('server', 'fastify').type('application/json').send(body);
        } else {
            reply.code(500).type('text/plain').send('No dataset');
        }
    });

    fastify.get('/db', (request, reply) => {
        if (!dbStmt) {
            return reply.header('server', 'fastify').type('application/json').send('{"items":[],"count":0}');
        }
        const min = parseFloat(request.query.min) || 10;
        const max = parseFloat(request.query.max) || 50;
        const rows = dbStmt.all(min, max);
        const items = rows.map(r => ({
            id: r.id, name: r.name, category: r.category,
            price: r.price, quantity: r.quantity, active: r.active === 1,
            tags: JSON.parse(r.tags),
            rating: { score: r.rating_score, count: r.rating_count }
        }));
        const body = JSON.stringify({ items, count: items.length });
        reply.header('server', 'fastify').type('application/json').send(body);
    });

    fastify.get('/async-db', async (request, reply) => {
        if (!pgPool) {
            return reply.header('server', 'fastify').type('application/json').send('{"items":[],"count":0}');
        }
        const min = parseInt(request.query.min, 10) || 10;
        const max = parseInt(request.query.max, 10) || 50;
        let limit = parseInt(request.query.limit, 10) || 50;
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
            reply.header('server', 'fastify').type('application/json').send(body);
        } catch (e) {
            reply.header('server', 'fastify').type('application/json').send('{"items":[],"count":0}');
        }
    });

    fastify.post('/upload', (request, reply) => {
        const payload = request.body;
        if (!payload || typeof payload.on !== 'function') {
            return reply.header('server', 'fastify').type('text/plain').send('0');
        }
        let size = 0;
        payload.on('data', chunk => size += chunk.length);
        payload.on('end', () => {
            reply.header('server', 'fastify').type('text/plain').send(String(size));
        });
    });

    fastify.get('/baseline2', (request, reply) => {
        reply.header('server', 'fastify').type('text/plain').send(String(sumQuery(request.query)));
    });

    fastify.route({
        method: ['GET', 'POST'],
        url: '/baseline11',
        handler: (request, reply) => {
            const querySum = sumQuery(request.query);
            const payload = request.body;
            if (request.method === 'POST' && payload && typeof payload.on === 'function') {
                let body = '';
                payload.on('data', chunk => body += chunk);
                payload.on('end', () => {
                    let total = querySum;
                    const n = parseInt(body.trim(), 10);
                    if (n === n) total += n;
                    reply.header('server', 'fastify').type('text/plain').send(String(total));
                });
            } else {
                reply.header('server', 'fastify').type('text/plain').send(String(querySum));
            }
        }
    });

    return fastify;
}

async function start() {
    const fs = require('fs');
    await (await build({})).listen({ port: 8080, host: '0.0.0.0' });

    // json-tls on 8081. The harness only mounts /certs for the TLS profiles.
    const cert = '/certs/server.crt';
    const key = '/certs/server.key';
    if (fs.existsSync(cert) && fs.existsSync(key)) {
        const tls = await build({ https: { key: fs.readFileSync(key), cert: fs.readFileSync(cert) } });
        await tls.listen({ port: 8081, host: '0.0.0.0' });
    }
}
