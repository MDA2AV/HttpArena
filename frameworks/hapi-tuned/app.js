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
    const http = require('http');
    const https = require('https');
    const { Transform } = require('stream');
    const Hapi = require('@hapi/hapi');

    // Tuned: brotli's fast end. 1 costs about a tenth less CPU per response
    // than 3 for a body about a fifth larger.
    const BROTLI_QUALITY = 1;

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
            // compression is hapi's response compression calling the brotli
            // encoder registered in start().
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

    // Tuned: brotli in one synchronous call instead of a zlib stream. A stream
    // sends every write, flush and close to the libuv thread pool and back,
    // which for a body of a few kilobytes costs more than the compression.
    // hapi still drives it: this is the encoder its compression calls, handed
    // the serialized payload and returning the coded one.
    const brotliOptions = { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: BROTLI_QUALITY } };
    function brotliEncoder() {
        const chunks = [];
        return new Transform({
            transform(chunk, encoding, callback) {
                chunks.push(chunk);
                callback();
            },
            flush(callback) {
                const body = chunks.length === 1 ? chunks[0] : Buffer.concat(chunks);
                callback(null, zlib.brotliCompressSync(body, brotliOptions));
            }
        });
    }

    // Tuned: the listener is created here and handed to hapi, so it can be
    // bound with reusePort. Every worker then has its own accept queue and the
    // kernel spreads connections over them, instead of the cluster primary
    // accepting each one and passing it to a worker over IPC.
    async function start(port, tls) {
        const listener = tls ? https.createServer(tls) : http.createServer();
        const server = Hapi.server({
            listener,
            autoListen: false,
            tls: !!tls,
            // Tuned: nothing here sets or reads cookies, serves ranges, or
            // needs connections tracked for a graceful stop.
            routes: { state: { parse: false }, response: { ranges: false } },
            operations: { cleanStop: false }
        });
        server.encoder('br', brotliEncoder);
        await server.register(routes);
        await server.start();
        await new Promise((resolve, reject) => {
            listener.once('error', reject);
            listener.listen({ port, host: '0.0.0.0', reusePort: true }, resolve);
        });
    }

    (async () => {
        await start(8080);

        // json-tls and 8gbit on 8081: a second hapi server on an https listener.
        // Every worker binds it as they all bind 8080. The harness only mounts
        // /certs for the TLS profiles, so without them it is not opened.
        const cert = '/certs/server.crt';
        const key = '/certs/server.key';
        if (fs.existsSync(cert) && fs.existsSync(key)) {
            await start(8081, { key: fs.readFileSync(key), cert: fs.readFileSync(cert) });
        }
    })().catch(err => {
        console.error(err);
        process.exit(1);
    });
}
