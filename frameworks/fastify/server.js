const cluster = require('cluster');
const os = require('os');
const fs = require('fs');
const http2 = require('http2');
const zlib = require('zlib');

const SERVER_NAME = 'fastify';

// --- Shared data (loaded per-worker) ---
let datasetItems;
let largeJsonBuf;
let dbStmt;
const staticFiles = {};
const MIME_TYPES = {
    '.css': 'text/css', '.js': 'application/javascript', '.html': 'text/html',
    '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.json': 'application/json'
};

function loadStaticFiles() {
    const dir = '/data/static';
    try {
        for (const name of fs.readdirSync(dir)) {
            const buf = fs.readFileSync(dir + '/' + name);
            const ext = name.slice(name.lastIndexOf('.'));
            staticFiles[name] = { buf, ct: MIME_TYPES[ext] || 'application/octet-stream' };
        }
    } catch (e) {}
}

function loadDataset() {
    const path = process.env.DATASET_PATH || '/data/dataset.json';
    try {
        datasetItems = JSON.parse(fs.readFileSync(path, 'utf8'));
    } catch (e) {}
}

function loadLargeDataset() {
    try {
        const raw = JSON.parse(fs.readFileSync('/data/dataset-large.json', 'utf8'));
        const items = raw.map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: Math.round(d.price * d.quantity * 100) / 100
        }));
        largeJsonBuf = Buffer.from(JSON.stringify({ items, count: items.length }));
    } catch (e) {}
}

function loadDatabase() {
    try {
        const Database = require('better-sqlite3');
        const db = new Database('/data/benchmark.db', { readonly: true });
        db.pragma('mmap_size=268435456');
        dbStmt = db.prepare('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50');
    } catch (e) {}
}

function sumQuery(query) {
    let sum = 0;
    if (query) {
        for (const key of Object.keys(query)) {
            const n = parseInt(query[key], 10);
            if (n === n) sum += n;
        }
    }
    return sum;
}

function startWorker() {
    loadDataset();
    loadLargeDataset();
    loadStaticFiles();
    loadDatabase();

    const Fastify = require('fastify');
    const app = Fastify({ logger: false, bodyLimit: 50 * 1024 * 1024 });

    // Register raw body parsers so req.body is available without manual stream reading
    app.addContentTypeParser('text/plain', { parseAs: 'string' }, (req, body, done) => done(null, body));
    app.addContentTypeParser('application/octet-stream', { parseAs: 'buffer' }, (req, body, done) => done(null, body));
    app.addContentTypeParser('*', { parseAs: 'buffer' }, (req, body, done) => done(null, body));

    // --- /pipeline ---
    app.get('/pipeline', (req, reply) => {
        reply.header('server', SERVER_NAME).type('text/plain').send('ok');
    });

    // --- /baseline11 GET & POST ---
    app.get('/baseline11', (req, reply) => {
        const s = sumQuery(req.query);
        reply.header('server', SERVER_NAME).type('text/plain').send(String(s));
    });

    app.post('/baseline11', (req, reply) => {
        const querySum = sumQuery(req.query);
        const body = typeof req.body === 'string' ? req.body : (req.body ? req.body.toString() : '');
        let total = querySum;
        const n = parseInt(body.trim(), 10);
        if (n === n) total += n;
        reply.header('server', SERVER_NAME).type('text/plain').send(String(total));
    });

    // --- /baseline2 ---
    app.get('/baseline2', (req, reply) => {
        const s = sumQuery(req.query);
        reply.header('server', SERVER_NAME).type('text/plain').send(String(s));
    });

    // --- /json ---
    app.get('/json', (req, reply) => {
        if (!datasetItems) {
            reply.code(500).send('No dataset');
            return;
        }
        const items = datasetItems.map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: Math.round(d.price * d.quantity * 100) / 100
        }));
        const buf = Buffer.from(JSON.stringify({ items, count: items.length }));
        reply
            .header('server', SERVER_NAME)
            .header('content-type', 'application/json')
            .header('content-length', buf.length)
            .send(buf);
    });

    // --- /compression ---
    app.get('/compression', (req, reply) => {
        if (!largeJsonBuf) {
            reply.code(500).send('No dataset');
            return;
        }
        const compressed = zlib.gzipSync(largeJsonBuf, { level: 1 });
        reply
            .header('server', SERVER_NAME)
            .header('content-type', 'application/json')
            .header('content-encoding', 'gzip')
            .header('content-length', compressed.length)
            .send(compressed);
    });

    // --- /db ---
    app.get('/db', (req, reply) => {
        if (!dbStmt) {
            reply.header('server', SERVER_NAME).type('application/json').send('{"items":[],"count":0}');
            return;
        }
        let min = 10, max = 50;
        if (req.query.min) min = parseFloat(req.query.min) || 10;
        if (req.query.max) max = parseFloat(req.query.max) || 50;
        const rows = dbStmt.all(min, max);
        const items = rows.map(r => ({
            id: r.id, name: r.name, category: r.category,
            price: r.price, quantity: r.quantity, active: r.active === 1,
            tags: JSON.parse(r.tags),
            rating: { score: r.rating_score, count: r.rating_count }
        }));
        const body = JSON.stringify({ items, count: items.length });
        reply
            .header('server', SERVER_NAME)
            .header('content-type', 'application/json')
            .header('content-length', Buffer.byteLength(body))
            .send(body);
    });

    // --- /upload ---
    app.post('/upload', (req, reply) => {
        const body = Buffer.isBuffer(req.body) ? req.body : Buffer.from(req.body || '');
        reply.header('server', SERVER_NAME).type('text/plain').send(String(body.length));
    });

    // Start HTTP/1.1 server
    app.listen({ port: 8080, host: '0.0.0.0' }).then(() => {
        // Also start HTTP/2 server on 8443
        startH2();
    });
}

function startH2() {
    const certFile = process.env.TLS_CERT || '/certs/server.crt';
    const keyFile = process.env.TLS_KEY || '/certs/server.key';
    try {
        const opts = {
            cert: fs.readFileSync(certFile),
            key: fs.readFileSync(keyFile),
            allowHTTP1: false,
        };
        const h2server = http2.createSecureServer(opts, (req, res) => {
            const url = req.url;
            const q = url.indexOf('?');
            const p = q === -1 ? url : url.slice(0, q);
            if (p.startsWith('/static/')) {
                const name = p.slice(8);
                const sf = staticFiles[name];
                if (sf) {
                    res.writeHead(200, { 'content-type': sf.ct, 'content-length': sf.buf.length, 'server': SERVER_NAME });
                    res.end(sf.buf);
                } else {
                    res.writeHead(404);
                    res.end();
                }
            } else {
                // baseline h2
                let sum = 0;
                if (q !== -1) {
                    const qs = url.slice(q + 1);
                    let i = 0;
                    while (i < qs.length) {
                        const eq = qs.indexOf('=', i);
                        if (eq === -1) break;
                        let amp = qs.indexOf('&', eq);
                        if (amp === -1) amp = qs.length;
                        const n = parseInt(qs.slice(eq + 1, amp), 10);
                        if (n === n) sum += n;
                        i = amp + 1;
                    }
                }
                res.writeHead(200, { 'content-type': 'text/plain', 'server': SERVER_NAME });
                res.end(String(sum));
            }
        });
        h2server.listen(8443);
    } catch (e) {
        // TLS certs not available, skip H2
    }
}

if (cluster.isPrimary) {
    const numCPUs = os.availableParallelism ? os.availableParallelism() : os.cpus().length;
    for (let i = 0; i < numCPUs; i++) cluster.fork();
} else {
    startWorker();
}
