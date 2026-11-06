// fulmine.js with app.uwsLite: an (req, res) route that uWS serves over two small objects.
// https://fulmine.sndesign.it/uws-routes#lite-routes-app-uwslite
const fs = require('fs');
const zlib = require('zlib');
const express = require('fulmine.js');

// One worker per usable core (cgroup quota first), all on the same port with SO_REUSEPORT.
// https://fulmine.sndesign.it/examples/cluster
const app = express({ cluster: 'auto' });

const dataset = JSON.parse(fs.readFileSync('/data/dataset.json', 'utf8'));

// Brotli quality 3, as the fulmine entry.
const compress = {
    encodings: ['br'],
    brotli: { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 3 } },
};

function sumQuery(query) {
    let sum = 0;
    for (const k in query) {
        const n = parseInt(query[k], 10);
        if (n === n) sum += n;
    }
    return sum;
}

app.uwsLite.get('/baseline11', (req, res) => {
    res.type('text/plain').send(String(sumQuery(req.query)));
});

app.uwsLite.post('/baseline11', { body: 'text' }, (req, res) => {
    let total = sumQuery(req.query);
    const n = parseInt(req.body.trim(), 10);
    if (n === n) total += n;
    res.type('text/plain').send(String(total));
});

app.uwsLite.get('/delay/:ms', (req, res) => {
    const ms = parseInt(req.params.ms, 10) || 0;
    setTimeout(() => res.type('text/plain').send(String(ms)), ms);
});

const json = (req, res) => {
    const count = Math.min(Math.max(parseInt(req.params.count, 10) || 0, 0), dataset.length);
    const m = parseInt(req.query.m, 10) || 1;
    const items = new Array(count);
    for (let i = 0; i < count; i++) {
        const d = dataset[i];
        items[i] = {
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m
        };
    }
    res.json({ items, count });
};

app.uwsLite.get('/json/:count', { compress }, json);

// json-tls and 8gbit over TLS on 8081, when the harness mounts the certs. json-tls never sends
// Accept-Encoding, so this route has no compress. The echo answers while the body is lent.
if (fs.existsSync('/certs/server.key') && fs.existsSync('/certs/server.crt')) {
    const tls = express({ uwsOptions: { key_file_name: '/certs/server.key', cert_file_name: '/certs/server.crt' } });
    tls.uwsLite.get('/json/:count', json);
    tls.uwsLite.post('/echo', { body: 'lent', limit: '1mb' }, (req, res) => {
        res.type('application/octet-stream').send(req.body);
    });
    tls.listen(8081);
}

app.listen(8080);
