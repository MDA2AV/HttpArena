const cluster = require('cluster');
const fs = require('fs');
const os = require('os');
const zlib = require('zlib');

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
    const uWS = require('uWebSockets.js');

    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    function sumQuery(query) {
        let sum = 0;
        for (const [, value] of new URLSearchParams(query)) {
            const n = parseInt(value, 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    const app = uWS.App();

    app.get('/pipeline', res => {
        res.writeHeader('Content-Type', 'text/plain').end('ok');
    });

    app.get('/baseline11', (res, req) => {
        const total = sumQuery(req.getQuery());
        res.writeHeader('Content-Type', 'text/plain').end(String(total));
    });

    app.post('/baseline11', (res, req) => {
        const querySum = sumQuery(req.getQuery());
        res.onAborted(() => { res.aborted = true; });
        let body = '';
        res.onData((chunk, isLast) => {
            body += Buffer.from(chunk).toString();
            if (!isLast || res.aborted) return;
            let total = querySum;
            const n = parseInt(body.trim(), 10);
            if (n === n) total += n;
            res.cork(() => {
                res.writeHeader('Content-Type', 'text/plain').end(String(total));
            });
        });
    });

    app.get('/json/:count', (res, req) => {
        const acceptEncoding = req.getHeader('accept-encoding');
        let count = parseInt(req.getParameter(0), 10) || 0;
        if (count < 0) count = 0;
        if (count > datasetItems.length) count = datasetItems.length;
        const m = parseInt(new URLSearchParams(req.getQuery()).get('m'), 10) || 1;

        const items = datasetItems.slice(0, count).map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m
        }));
        const body = JSON.stringify({ items, count });

        // uWebSockets.js has no compression middleware, so json-comp is served by
        // gzipping the body with the Node zlib bindings when the client asks for it
        if (acceptEncoding.includes('gzip')) {
            const compressed = zlib.gzipSync(body);
            res.cork(() => {
                res.writeHeader('Content-Type', 'application/json')
                    .writeHeader('Content-Encoding', 'gzip')
                    .end(compressed);
            });
        } else {
            res.cork(() => {
                res.writeHeader('Content-Type', 'application/json').end(body);
            });
        }
    });

    app.post('/upload', res => {
        res.onAborted(() => { res.aborted = true; });
        let size = 0;
        res.onData((chunk, isLast) => {
            size += chunk.byteLength;
            if (!isLast || res.aborted) return;
            res.cork(() => {
                res.writeHeader('Content-Type', 'text/plain').end(String(size));
            });
        });
    });

    app.listen(8080, () => {});
}
