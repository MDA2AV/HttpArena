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

    // max_body_length defaults to 250 KB and answers 413 above it, so the upload profile,
    // which posts up to 20 MB, needs the cap raised. Every worker binds :8080 on its own:
    // uWebSockets.js shares the port between processes unless exclusive_port is asked for.
    const server = new Server({ max_body_length: 32 * 1024 * 1024 });

    const SERVER_HDR = 'hyper-express';

    // Dataset
    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    function sumQuery(query) {
        let sum = 0;
        for (const k in query) {
            const n = parseInt(query[k], 10);
            if (n === n) sum += n;
        }
        return sum;
    }

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

    // The request is a lazy Readable: counting bytes never needs the 20 MB body in memory,
    // which is what request.buffer() would cost
    server.post('/upload', (request, response) => {
        let size = 0;
        request.on('data', chunk => size += chunk.length);
        request.on('end', () => {
            response.header('server', SERVER_HDR).type('text/plain').send(String(size));
        });
    });

    server.any('/baseline11', async (request, response) => {
        let total = sumQuery(request.query_parameters);
        if (request.method === 'POST') {
            const n = parseInt((await request.text()).trim(), 10);
            if (n === n) total += n;
        }
        response.header('server', SERVER_HDR).type('text/plain').send(String(total));
    });

    server.listen(8080);
}
