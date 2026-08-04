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
    const fastify = require('fastify')({ logger: false });
    const fs = require('fs');
    const zlib = require('zlib');
    // level 1: the arena measures throughput of compressed JSON, and the payloads are small
    // enough that a higher level buys bytes nobody counts
    const GZIP_OPTS = { level: 1 };
    const Database = require('better-sqlite3');

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

    // MIME types for static files
    const MIME_TYPES = {
        '.css': 'text/css', '.js': 'application/javascript', '.html': 'text/html',
        '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.json': 'application/json',
    };

    // Pre-load static files with pre-compressed variants
    const staticFiles = {};
    try {
        for (const name of fs.readdirSync('/data/static')) {
            if (name.endsWith('.br') || name.endsWith('.gz')) continue;
            const buf = fs.readFileSync(`/data/static/${name}`);
            const ext = name.slice(name.lastIndexOf('.'));
            let br = null, gz = null;
            try { br = fs.readFileSync(`/data/static/${name}.br`); } catch (_) {}
            try { gz = fs.readFileSync(`/data/static/${name}.gz`); } catch (_) {}
            staticFiles[name] = { buf, br, gz, ct: MIME_TYPES[ext] || 'application/octet-stream' };
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
            // json-comp profile: negotiated per request, nothing without Accept-Encoding
            const ae = request.headers['accept-encoding'] || '';
            if (ae.includes('gzip')) {
                reply.header('server', 'fastify').header('content-encoding', 'gzip')
                    .type('application/json')
                    .send(zlib.gzipSync(body, GZIP_OPTS));
            } else if (ae.includes('br')) {
                reply.header('server', 'fastify').header('content-encoding', 'br')
                    .type('application/json')
                    .send(zlib.brotliCompressSync(body, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 } }));
            } else {
                reply.header('server', 'fastify').type('application/json').send(body);
            }
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

    fastify.get('/static/:filename', (request, reply) => {
        const sf = staticFiles[request.params.filename];
        if (!sf) return reply.code(404).type('text/plain').send('Not found');
        const ae = request.headers['accept-encoding'] || '';
        if (sf.br && ae.includes('br')) {
            reply.header('server', 'fastify').header('content-encoding', 'br').header('content-type', sf.ct).send(sf.br);
        } else if (sf.gz && ae.includes('gzip')) {
            reply.header('server', 'fastify').header('content-encoding', 'gzip').header('content-type', sf.ct).send(sf.gz);
        } else {
            reply.header('server', 'fastify').header('content-type', sf.ct).send(sf.buf);
        }
    });

    fastify.listen({ port: 8080, host: '0.0.0.0' });
}
