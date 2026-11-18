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
    const { setTimeout: sleep } = require('node:timers/promises');
    const zlib = require('zlib');
    const Hapi = require('@hapi/hapi');

    let datasetItems = [];
    try {
        datasetItems = JSON.parse(fs.readFileSync(process.env.DATASET_PATH || '/data/dataset.json', 'utf8'));
    } catch (e) {}

    function sumQuery(query) {
        let sum = 0;
        for (const key in query) {
            const n = parseInt(query[key], 10);
            if (n === n) sum += n;
        }
        return sum;
    }

    // The routes are a hapi plugin so the plaintext and the TLS server register
    // the same definitions rather than two copies.
    const routes = {
        name: 'httparena-routes',
        register(server) {
            server.route({
                method: 'GET',
                path: '/pipeline',
                handler: (request, h) => h.response('ok').type('text/plain')
            });

            // request.query and request.payload are hapi's own parsing: the
            // payload arrives as a string because the body is text/plain,
            // whether it was framed by Content-Length or chunked.
            server.route({
                method: 'GET',
                path: '/baseline11',
                handler: (request, h) => h.response(String(sumQuery(request.query))).type('text/plain')
            });

            server.route({
                method: 'POST',
                path: '/baseline11',
                options: { payload: { defaultContentType: 'text/plain' } },
                handler: (request, h) => {
                    let total = sumQuery(request.query);
                    const n = parseInt(request.payload, 10);
                    if (n === n) total += n;
                    return h.response(String(total)).type('text/plain');
                }
            });

            // A promise-based sleep yields to the event loop rather than holding
            // it, so the waits in flight are bounded by memory.
            server.route({
                method: 'GET',
                path: '/delay/{ms}',
                handler: async (request, h) => {
                    const ms = Number(request.params.ms);
                    if (!Number.isInteger(ms) || ms < 0) {
                        return h.response().code(404);
                    }
                    if (ms > 0) await sleep(ms);
                    return h.response(String(ms)).type('text/plain');
                }
            });

            // Returning an object makes hapi serialize it as application/json;
            // compression is hapi's built-in response compression, with the
            // brotli encoder registered in start().
            server.route({
                method: 'GET',
                path: '/json/{count}',
                handler: request => {
                    let count = parseInt(request.params.count, 10) || 0;
                    if (count < 0) count = 0;
                    if (count > datasetItems.length) count = datasetItems.length;
                    const m = parseInt(request.query.m, 10) || 1;
                    const items = datasetItems.slice(0, count).map(d => ({
                        id: d.id, name: d.name, category: d.category,
                        price: d.price, quantity: d.quantity, active: d.active,
                        tags: d.tags, rating: d.rating,
                        total: d.price * d.quantity * m
                    }));
                    return { items, count };
                }
            });

            // parse: false hands the handler the raw body as a Buffer. hapi
            // answers an empty payload with 204 unless emptyStatusCode says
            // otherwise, and an empty echo is specified as a 200.
            server.route({
                method: 'POST',
                path: '/echo',
                options: {
                    payload: { parse: false, output: 'data' },
                    response: { emptyStatusCode: 200 }
                },
                handler: (request, h) =>
                    h.response(request.payload || Buffer.alloc(0)).type('application/octet-stream')
            });
        }
    };

    async function start(options) {
        const server = Hapi.server(options);

        // hapi ships gzip and deflate; brotli is added through its encoder
        // API using Node's zlib. Quality 3 rather than zlib's default of 11,
        // which is meant for static assets and costs ~50x the CPU per response.
        // At 3 it is cheaper than hapi's gzip for a body about the same size;
        // at 4 brotli moves to a larger hash table and costs more than gzip.
        server.encoder('br', () => zlib.createBrotliCompress({
            params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 }
        }));

        await server.register(routes);
        await server.start();
    }

    (async () => {
        await start({ port: 8080 });

        // json-tls and 8gbit on 8081: a second hapi server with the tls option.
        // Every worker binds it as they all bind 8080. The harness only mounts
        // /certs for the TLS profiles, so without them it is not opened.
        const cert = '/certs/server.crt';
        const key = '/certs/server.key';
        if (fs.existsSync(cert) && fs.existsSync(key)) {
            await start({
                port: 8081,
                tls: { key: fs.readFileSync(key), cert: fs.readFileSync(cert) }
            });
        }
    })().catch(err => {
        console.error(err);
        process.exit(1);
    });
}
