import cluster from 'node:cluster';
import os from 'node:os';
import fs from 'node:fs';

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
    const { createVelocity } = await import('velocity');

    let datasetItems;
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    const sumQuery = (query) => {
        let sum = 0;
        for (const k in query) {
            const n = parseInt(query[k], 10);
            if (n === n) sum += n;
        }
        return sum;
    };

    const sendText = (res, text) => {
        res.setHeader('Content-Type', 'text/plain');
        res.end(text);
    };

    // The same routes are served on 8080 and, behind TLS, on 8081.
    const register = (app) => {
        app.get('/pipeline', (req, res) => sendText(res, 'ok'));

        app.get('/baseline11', (req, res) => sendText(res, String(sumQuery(req.search))));

        app.post('/baseline11', (req, res) => {
            const querySum = sumQuery(req.search);
            let body = '';
            req.on('data', (chunk) => (body += chunk));
            req.on('end', () => {
                let total = querySum;
                const n = parseInt(body.trim(), 10);
                if (n === n) total += n;
                sendText(res, String(total));
            });
        });

        // GET /delay/{ms}: answer after ms milliseconds without holding the event loop.
        app.get('/delay/:ms', (req, res) => {
            const ms = parseInt(req.vars.ms, 10) || 0;
            setTimeout(() => sendText(res, String(ms)), ms);
        });

        app.post('/echo', (req, res) => {
            const chunks = [];
            req.on('data', (chunk) => chunks.push(chunk));
            req.on('end', () => {
                res.setHeader('Content-Type', 'application/octet-stream');
                res.end(Buffer.concat(chunks));
            });
        });

        app.get('/json/:count', (req, res) => {
            if (!datasetItems) return res.setStatus(500).end('No dataset');
            let count = parseInt(req.vars.count, 10) || 0;
            if (count < 0) count = 0;
            if (count > datasetItems.length) count = datasetItems.length;
            const m = parseInt(req.search.m, 10) || 1;
            const items = datasetItems.slice(0, count).map((d) => ({
                id: d.id, name: d.name, category: d.category,
                price: d.price, quantity: d.quantity, active: d.active,
                tags: d.tags, rating: d.rating,
                total: d.price * d.quantity * m
            }));
            // json-comp negotiation is velocity's built-in compression, enabled below
            return res.sendJson({ items, count });
        });

        return app;
    };

    register(createVelocity({ compression: true })).start(8080);

    // json-tls and 8gbit on 8081. The harness only mounts /certs for the TLS profiles.
    const CERT = process.env.TLS_CERT || '/certs/server.crt';
    const KEY = process.env.TLS_KEY || '/certs/server.key';
    if (fs.existsSync(CERT) && fs.existsSync(KEY)) {
        const tls = {
            cert: fs.readFileSync(CERT),
            key: fs.readFileSync(KEY),
            ALPNProtocols: ['http/1.1']
        };
        register(createVelocity({ compression: true, https: tls })).start(8081);
    }
}
