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
    const fs = require('fs');
    const Koa = require('koa');
    const Router = require('@koa/router');
    const compress = require('koa-compress');

    const app = new Koa();
    const router = new Router();

    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    // standard mode: compression is the stock koa-compress middleware with its defaults
    app.use(compress());

    function sumQuery(query) {
        let sum = 0;
        for (const key in query) {
            const n = parseInt(query[key], 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    function readBody(req) {
        return new Promise((resolve, reject) => {
            let body = '';
            req.on('data', chunk => body += chunk);
            req.on('end', () => resolve(body));
            req.on('error', reject);
        });
    }

    router.get('/pipeline', ctx => {
        ctx.type = 'text/plain';
        ctx.body = 'ok';
    });

    async function baseline11(ctx) {
        let total = sumQuery(ctx.query);
        if (ctx.method === 'POST') {
            const n = parseInt((await readBody(ctx.req)).trim(), 10);
            if (n === n) total += n;
        }
        ctx.type = 'text/plain';
        ctx.body = String(total);
    }

    router.get('/baseline11', baseline11);
    router.post('/baseline11', baseline11);

    router.get('/json/:count', ctx => {
        let count = parseInt(ctx.params.count, 10) || 0;
        if (count < 0) count = 0;
        if (count > datasetItems.length) count = datasetItems.length;
        const m = parseInt(ctx.query.m, 10) || 1;
        const items = datasetItems.slice(0, count).map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m
        }));
        ctx.body = { items, count };
    });

    router.post('/upload', async ctx => {
        let size = 0;
        for await (const chunk of ctx.req) size += chunk.length;
        ctx.type = 'text/plain';
        ctx.body = String(size);
    });

    app.use(router.routes());
    app.listen(8080);
}
