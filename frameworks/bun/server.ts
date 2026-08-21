type Item = {
    id: number;
    name: string;
    category: string;
    price: number;
    quantity: number;
    active: boolean;
    tags: string[];
    rating: { score: number; count: number };
};

// A missing dataset is not fatal: /json answers with an empty list so the other
// profiles still run.
let dataset: Item[] = [];
try {
    dataset = await Bun.file(process.env.DATASET_PATH || "/data/dataset.json").json();
} catch {}

const TEXT = { "content-type": "text/plain", "server": "bun" };
const JSON_PLAIN = { "content-type": "application/json", "server": "bun" };
const JSON_GZIP = { "content-type": "application/json", "content-encoding": "gzip", "server": "bun" };

function sumQuery(query: string): number {
    let sum = 0;
    for (const pair of query.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        const n = parseInt(pair.slice(eq + 1), 10);
        if (!Number.isNaN(n)) sum += n;
    }
    return sum;
}

function multiplier(query: string): number {
    for (const pair of query.split("&")) {
        if (pair.startsWith("m=")) {
            const n = parseInt(pair.slice(2), 10);
            if (!Number.isNaN(n)) return n;
        }
    }
    return 1;
}

async function baseline11Post(req: Request, sum: number): Promise<Response> {
    const n = parseInt((await req.text()).trim(), 10);
    return new Response(String(Number.isNaN(n) ? sum : sum + n), { headers: TEXT });
}

function json(path: string, query: string, req: Request): Response {
    let count = parseInt(path.slice(6), 10);
    if (!(count > 0)) count = 0;
    if (count > dataset.length) count = dataset.length;
    const m = multiplier(query);

    const items = new Array(count);
    for (let i = 0; i < count; i++) {
        const d = dataset[i]!;
        items[i] = {
            id: d.id, name: d.name, category: d.category,
            price: d.price, quantity: d.quantity, active: d.active,
            tags: d.tags, rating: d.rating,
            total: d.price * d.quantity * m,
        };
    }
    const body = JSON.stringify({ items, count });

    // Bun.serve does no content negotiation, so json-comp is compressed here, and
    // only when the client asked for it: a Content-Encoding nobody accepted is a
    // validation failure.
    const accept = req.headers.get("accept-encoding");
    if (accept !== null && accept.includes("gzip")) {
        return new Response(Bun.gzipSync(body), { headers: JSON_GZIP });
    }
    return new Response(body, { headers: JSON_PLAIN });
}

async function upload(req: Request): Promise<Response> {
    let size = 0;
    const body = req.body;
    if (body !== null) {
        // Counted chunk by chunk. The profile posts up to 20 MB per request over
        // hundreds of connections, and buffering the bodies would only cost memory.
        for await (const chunk of body) size += chunk.byteLength;
    }
    return new Response(String(size), { headers: TEXT });
}

function handle(req: Request): Response | Promise<Response> {
    // req.url is absolute, so the path starts at the first slash after the host.
    const url = req.url;
    const start = url.indexOf("/", 8);
    const q = url.indexOf("?", start);
    const path = q < 0 ? url.slice(start) : url.slice(start, q);
    const query = q < 0 ? "" : url.slice(q + 1);

    if (path === "/pipeline") return new Response("ok", { headers: TEXT });

    if (path === "/baseline11") {
        const sum = sumQuery(query);
        if (req.method === "POST") return baseline11Post(req, sum);
        return new Response(String(sum), { headers: TEXT });
    }

    if (path.startsWith("/json/")) return json(path, query, req);

    if (path === "/upload" && req.method === "POST") return upload(req);

    if (path === "/baseline2") return new Response(String(sumQuery(query)), { headers: TEXT });

    return new Response("Not Found", { status: 404, headers: TEXT });
}

Bun.serve({
    port: 8080,
    hostname: "0.0.0.0",
    // Every worker process binds the same port and the kernel spreads the accepts,
    // which is how this entry uses more than one core.
    reusePort: true,
    development: false,
    // A 20 MB upload on a saturated server takes longer than the 10s default.
    idleTimeout: 120,
    fetch: handle,
});

console.log("Application started.");
