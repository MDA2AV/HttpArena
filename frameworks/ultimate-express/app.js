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
    const express = require('ultimate-express');
    const fs = require('fs');
    const Database = require('better-sqlite3');

    const app = express();
    app.disable('x-powered-by');
    app.set('etag', false);

    const SERVER_HDR = { 'server': 'ultimate-express' };

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

    app.get('/pipeline', (req, res) => {
        res.set(SERVER_HDR).type('text/plain').send('ok');
    });

    app.get('/json/:count', (req, res) => {
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
            res.set(SERVER_HDR).type('application/json').send(body);
        } else {
            res.status(500).send('No dataset');
        }
    });

    app.get('/db', (req, res) => {
        if (!dbStmt) {
            return res.set(SERVER_HDR).type('application/json').send('{"items":[],"count":0}');
        }
        const min = parseFloat(req.query.min) || 10;
        const max = parseFloat(req.query.max) || 50;
        const rows = dbStmt.all(min, max);
        const items = rows.map(r => ({
            id: r.id, name: r.name, category: r.category,
            price: r.price, quantity: r.quantity, active: r.active === 1,
            tags: JSON.parse(r.tags),
            rating: { score: r.rating_score, count: r.rating_count }
        }));
        const body = JSON.stringify({ items, count: items.length });
        res.set(SERVER_HDR).type('application/json').send(body);
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
            res.set(SERVER_HDR).type('application/json').send(body);
        } catch (e) {
            res.set(SERVER_HDR).type('application/json').send('{"items":[],"count":0}');
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

    app.get('/static/:filename', (req, res) => {
        const sf = staticFiles[req.params.filename];
        if (!sf) return res.status(404).send('Not found');
        const ae = req.headers['accept-encoding'] || '';
        if (sf.br && ae.includes('br')) {
            res.set({ ...SERVER_HDR, 'content-type': sf.ct, 'content-encoding': 'br', 'content-length': String(sf.br.length) }).send(sf.br);
        } else if (sf.gz && ae.includes('gzip')) {
            res.set({ ...SERVER_HDR, 'content-type': sf.ct, 'content-encoding': 'gzip', 'content-length': String(sf.gz.length) }).send(sf.gz);
        } else {
            res.set({ ...SERVER_HDR, 'content-type': sf.ct, 'content-length': String(sf.buf.length) }).send(sf.buf);
        }
    });

    app.listen(8080);
}
