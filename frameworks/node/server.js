// node:http with nothing on top: no framework, no router, no dependencies. This is
// the floor the node framework entries are read against.
const cluster = require('node:cluster');
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const zlib = require('node:zlib');

// The container is pinned to a cpuset or a cpu quota, so availableParallelism()
// alone would fork one worker per host core. Same helper as the other node entries.
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
    // A missing dataset serves an empty list instead of taking the worker down
    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    const SERVER_HDR = 'node';

    function sendText(res, body) {
        res.writeHead(200, {
            'content-type': 'text/plain',
            'content-length': Buffer.byteLength(body),
            'server': SERVER_HDR
        });
        res.end(body);
    }

    // No querystring module and no URL object: the profiles send a handful of
    // integer parameters, and parsing them by hand is the whole cost here.
    function sumQuery(query) {
        let sum = 0;
        for (const pair of query.split('&')) {
            const eq = pair.indexOf('=');
            if (eq < 0) continue;
            const n = parseInt(pair.slice(eq + 1), 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    function queryValue(query, name) {
        for (const pair of query.split('&')) {
            if (pair.startsWith(name) && pair[name.length] === '=') {
                return pair.slice(name.length + 1);
            }
        }
        return '';
    }

    function json(req, res, path, query) {
        let count = parseInt(path.slice(6), 10) || 0;
        if (count < 0) count = 0;
        if (count > datasetItems.length) count = datasetItems.length;
        const m = parseInt(queryValue(query, 'm'), 10) || 1;
        const items = datasetItems.slice(0, count).map(d => ({
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m
        }));
        const body = JSON.stringify({ items, count });

        // json-comp: node:http negotiates nothing, so Accept-Encoding is read here,
        // per request, with the zlib defaults. Nothing at all when it is not asked for
        const accept = req.headers['accept-encoding'];
        if (accept !== undefined && accept.includes('gzip')) {
            const gz = zlib.gzipSync(body);
            res.writeHead(200, {
                'content-type': 'application/json',
                'content-encoding': 'gzip',
                'vary': 'accept-encoding',
                'content-length': gz.length,
                'server': SERVER_HDR
            });
            res.end(gz);
            return;
        }
        res.writeHead(200, {
            'content-type': 'application/json',
            'content-length': Buffer.byteLength(body),
            'server': SERVER_HDR
        });
        res.end(body);
    }

    const server = http.createServer((req, res) => {
        // req.url is the request target, so the path is everything before the "?"
        const url = req.url;
        const mark = url.indexOf('?');
        const path = mark < 0 ? url : url.slice(0, mark);
        const query = mark < 0 ? '' : url.slice(mark + 1);

        if (path === '/pipeline') return sendText(res, 'ok');

        if (path === '/baseline11') {
            const querySum = sumQuery(query);
            if (req.method !== 'POST') return sendText(res, String(querySum));
            // Content-Length or chunked, node:http gives the same data events either way
            let body = '';
            req.setEncoding('utf8');
            req.on('data', chunk => body += chunk);
            req.on('end', () => {
                let total = querySum;
                const n = parseInt(body.trim(), 10);
                if (n === n) total += n;
                sendText(res, String(total));
            });
            return;
        }

        if (path.startsWith('/json/')) return json(req, res, path, query);

        if (path === '/upload' && req.method === 'POST') {
            // Counted chunk by chunk: the profile posts up to 20 MB per request over
            // hundreds of connections, and buffering the bodies would only cost memory
            let size = 0;
            req.on('data', chunk => size += chunk.length);
            req.on('end', () => sendText(res, String(size)));
            return;
        }

        if (path === '/baseline2') return sendText(res, String(sumQuery(query)));

        res.writeHead(404, { 'content-type': 'text/plain', 'content-length': 9, 'server': SERVER_HDR });
        res.end('Not found');
    });

    // Scaling is cluster to fork the workers, but not its round robin: with reusePort
    // every worker binds 8080 itself with SO_REUSEPORT and the kernel spreads the
    // accepts, the way bun and deno do it. node sets exclusive on its own when
    // reusePort is true, so the cluster listen path is out of the way.
    server.listen({ port: 8080, host: '0.0.0.0', reusePort: true });
}
