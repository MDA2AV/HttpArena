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

    const app = createVelocity({ compression: true });

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
        return res.sendJson({ items, count });
    });

    app.start(8080);
}
