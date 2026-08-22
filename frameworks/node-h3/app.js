import cluster from 'node:cluster';
import os from 'node:os';
import fs from 'node:fs';
import zlib from 'node:zlib';
import { H3, serve, getQuery, getRouterParam, getBodyStream, readBody } from 'h3';

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
    const app = new H3();
    const SERVER_HDR = 'h3';

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

    app.get('/pipeline', (event) => {
        event.res.headers.set('server', SERVER_HDR);
        event.res.headers.set('content-type', 'text/plain');
        return 'ok';
    });

    app.get('/json/:count', (event) => {
        let count = parseInt(getRouterParam(event, 'count'), 10) || 0;
        if (count < 0) count = 0;
        if (count > datasetItems.length) count = datasetItems.length;
        const m = parseInt(getQuery(event).m, 10) || 1;
        const items = datasetItems.slice(0, count).map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m
        }));
        // json-comp: h3 ships no compression middleware, so the negotiation is here, per
        // request, with the zlib defaults. Nothing at all without Accept-Encoding
        event.res.headers.set('server', SERVER_HDR);
        const accept = event.req.headers.get('accept-encoding');
        if (accept && accept.includes('gzip')) {
            event.res.headers.set('content-type', 'application/json');
            event.res.headers.set('content-encoding', 'gzip');
            return zlib.gzipSync(JSON.stringify({ items, count }));
        }
        return { items, count };
    });

    app.post('/upload', async (event) => {
        // counted as it arrives: the profile posts bodies up to 20 MB
        let size = 0;
        const stream = getBodyStream(event);
        if (stream) {
            const reader = stream.getReader();
            for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                size += value.byteLength;
            }
        }
        event.res.headers.set('server', SERVER_HDR);
        event.res.headers.set('content-type', 'text/plain');
        return String(size);
    });

    app.get('/baseline11', (event) => {
        event.res.headers.set('server', SERVER_HDR);
        event.res.headers.set('content-type', 'text/plain');
        return String(sumQuery(getQuery(event)));
    });

    app.post('/baseline11', async (event) => {
        let total = sumQuery(getQuery(event));
        const body = await readBody(event, { type: 'text' });
        const n = parseInt(body.trim(), 10);
        if (n === n) total += n;
        event.res.headers.set('server', SERVER_HDR);
        event.res.headers.set('content-type', 'text/plain');
        return String(total);
    });

    // reusePort is how srvx asks for a non-exclusive bind. Its default is exclusive, so
    // under cluster only the first worker gets port 8080 and the others fail with
    // EADDRINUSE, silently: srvx catches the listen error, so they stay up serving nothing
    serve(app, { port: 8080, hostname: '0.0.0.0', reusePort: true, silent: true });

    // json-tls on 8081. srvx (h3's server layer) takes the PEM paths directly and
    // builds the node:https server itself, so this is the same h3 app on both
    // ports. Certs are only mounted for the TLS profiles, hence the guard.
    if (fs.existsSync('/certs/server.crt') && fs.existsSync('/certs/server.key')) {
        serve(app, {
            port: 8081, hostname: '0.0.0.0', reusePort: true, silent: true,
            tls: { cert: '/certs/server.crt', key: '/certs/server.key' },
        });
    }
}
