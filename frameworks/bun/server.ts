import { SQL, RedisClient } from "bun";

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
const HTML = { "content-type": "text/html; charset=utf-8", "server": "bun" };
const JSON_HIT = { "content-type": "application/json", "server": "bun", "x-cache": "HIT" };
const JSON_MISS = { "content-type": "application/json", "server": "bun", "x-cache": "MISS" };
const JSON_PLAIN = { "content-type": "application/json", "server": "bun" };
const JSON_GZIP = { "content-type": "application/json", "content-encoding": "gzip", "server": "bun" };

// Postgres and Redis are Bun's own - Bun.SQL and Bun.RedisClient ship with the
// runtime, so the database profiles cost this entry no dependency. DATABASE_URL
// is only set for the profiles that need it, so both stay null otherwise and the
// handlers answer without touching them.
//
// The pool is per process and this entry runs one process per core, so the
// harness's DATABASE_MAX_CONN is split across them rather than opened by each.
const WORKERS = Math.max(1, parseInt(process.env.BUN_WORKERS || "1", 10) || 1);
const POOL = Math.max(1, Math.floor(
    (parseInt(process.env.DATABASE_MAX_CONN || "256", 10) || 256) / WORKERS));

const sql = process.env.DATABASE_URL
    ? new SQL(process.env.DATABASE_URL, { max: POOL })
    : null;
const redis = process.env.REDIS_URL ? new RedisClient(process.env.REDIS_URL) : null;

const ITEM_COLUMNS =
    "id, name, category, price, quantity, active, tags, rating_score, rating_count";
type Row = {
    id: number; name: string; category: string; price: number; quantity: number;
    active: boolean; tags: unknown; rating_score: number; rating_count: number;
};
const itemShape = (r: Row) => ({
    id: r.id, name: r.name, category: r.category, price: r.price,
    quantity: r.quantity, active: r.active, tags: r.tags,
    rating: { score: r.rating_score, count: r.rating_count },
});

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

function json(count_: string, query: string, req: Request): Response {
    let count = parseInt(count_, 10);
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

// ── static ──────────────────────────────────────────────────────────────────
// Content-Type is mapped here rather than left to Bun.file's sniffing: the
// profile checks the header on woff2 and webp among others, and an explicit
// table is the only way to be sure of what goes out.
//
// Bun.file() is a lazy handle - the bytes are read when the Response is streamed
// and nothing is retained between requests, which is what the profile requires
// of a framework entry.
//
// Bun.serve has no pre-compressed static API of its own, so the .br/.gz variants
// the harness leaves on disk are selected here. Nothing is compressed at
// runtime: the encoded bytes already exist next to the original, and picking one
// is a read of a different path. Selection stays lazy for the same reason the
// plain path is - the variant is a Bun.file handle too, so replacing either file
// on disk shows up on the next request.
const MIME: Record<string, string> = {
    css: "text/css", js: "text/javascript", html: "text/html",
    woff2: "font/woff2", svg: "image/svg+xml", webp: "image/webp",
    json: "application/json",
};

// Static responses carry Content-Type and, when encoded, Content-Encoding, and
// nothing else. Vary: Accept-Encoding is correct HTTP and is what most static
// handlers send, but the profile scores bandwidth and it is ~38 bytes a response
// together with Server, so both are left off here.
//
// Brotli first: it is the smaller of the two and every client that sends br
// also sends gzip. A client asking for neither gets the original bytes.
const ENCODINGS: ReadonlyArray<readonly [string, string]> = [
    ["br", ".br"],
    ["gzip", ".gz"],
];

async function serveStatic(name: string, req: Request): Promise<Response> {
    // No traversal outside the mount, and no directory reads.
    if (name.length === 0 || name.includes("/") || name.includes("..")) {
        return new Response("Not Found", { status: 404, headers: TEXT });
    }
    const base = "/data/static/" + name;
    const file = Bun.file(base);
    if (!(await file.exists())) {
        return new Response("Not Found", { status: 404, headers: TEXT });
    }
    const dot = name.lastIndexOf(".");
    const type = (dot > 0 && MIME[name.slice(dot + 1)]) || "application/octet-stream";

    // Content-Type stays that of the original file; only the encoding differs.
    const accept = req.headers.get("accept-encoding") ?? "";
    for (const [token, suffix] of ENCODINGS) {
        if (!accept.includes(token)) continue;
        const encoded = Bun.file(base + suffix);
        if (await encoded.exists()) {
            // Only the two headers the response is wrong without: Bun infers
            // Content-Type from the .br/.gz suffix and gets it wrong, and it
            // never sets Content-Encoding. Vary and Server are deliberately
            // not sent - see the note above serveStatic.
            return new Response(encoded, {
                headers: { "content-type": type, "content-encoding": token },
            });
        }
    }

    return new Response(file, { headers: { "content-type": type } });
}

// ── database ────────────────────────────────────────────────────────────────
const EMPTY_ITEMS = '{"items":[],"count":0}';

async function asyncDb(query: string): Promise<Response> {
    if (!sql) return new Response(EMPTY_ITEMS, { headers: JSON_PLAIN });
    const p = new URLSearchParams(query);
    const min = parseInt(p.get("min") || "", 10) || 10;
    const max = parseInt(p.get("max") || "", 10) || 50;
    let limit = parseInt(p.get("limit") || "", 10) || 50;
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;
    try {
        const rows: Row[] = await sql.unsafe(
            `SELECT ${ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3`,
            [min, max, limit]);
        const items = rows.map(itemShape);
        return new Response(JSON.stringify({ items, count: items.length }),
            { headers: JSON_PLAIN });
    } catch {
        return new Response(EMPTY_ITEMS, { headers: JSON_PLAIN });
    }
}

const dbError = (msg: string, status = 500) =>
    new Response(`{"error":"${msg}"}`, { status, headers: JSON_PLAIN });

async function crudList(query: string): Promise<Response> {
    if (!sql) return dbError("DB not available");
    const p = new URLSearchParams(query);
    const category = p.get("category") || "electronics";
    const page = Math.max(1, parseInt(p.get("page") || "", 10) || 1);
    let limit = parseInt(p.get("limit") || "", 10) || 10;
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;
    try {
        const rows: Row[] = await sql.unsafe(
            `SELECT ${ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3`,
            [category, limit, (page - 1) * limit]);
        const items = rows.map(itemShape);
        return new Response(
            JSON.stringify({ items, total: items.length, page, limit }),
            { headers: JSON_PLAIN });
    } catch {
        return dbError("query failed");
    }
}

// Cache-aside on Redis when the harness provides it - crud is the one profile
// that does, and it is shared across this entry's worker processes, which a
// per-process map would not be.
const CRUD_TTL_MS = 200;

async function crudRead(id: number): Promise<Response> {
    if (!sql) return dbError("DB not available");
    if (!Number.isFinite(id)) return new Response(null, { status: 404 });
    try {
        if (redis) {
            const hit = await redis.get("crud:" + id);
            if (hit) return new Response(hit, { headers: JSON_HIT });
        }
        const rows: Row[] = await sql.unsafe(
            `SELECT ${ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1`, [id]);
        if (rows.length === 0) return new Response(null, { status: 404 });
        const body = JSON.stringify(itemShape(rows[0]!));
        if (redis) redis.set("crud:" + id, body, "PX", String(CRUD_TTL_MS));
        return new Response(body, { headers: JSON_MISS });
    } catch {
        return dbError("query failed");
    }
}

async function crudCreate(req: Request): Promise<Response> {
    if (!sql) return dbError("DB not available");
    try {
        const b = await req.json() as Record<string, any>;
        const rows: { id: number }[] = await sql.unsafe(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
            "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) " +
            "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id",
            [b.id, b.name ?? "New Product", b.category ?? "test", b.price ?? 0, b.quantity ?? 0]);
        return new Response(JSON.stringify({
            id: rows[0]!.id, name: b.name, category: b.category,
            price: b.price, quantity: b.quantity,
        }), { status: 201, headers: JSON_PLAIN });
    } catch {
        return dbError("insert failed");
    }
}

async function crudUpdate(req: Request, id: number): Promise<Response> {
    if (!sql) return dbError("DB not available");
    if (!Number.isFinite(id)) return new Response(null, { status: 404 });
    try {
        const b = await req.json() as Record<string, any>;
        const rows = await sql.unsafe(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4 RETURNING id",
            [b.name ?? "Updated", b.price ?? 0, b.quantity ?? 0, id]);
        if (rows.length === 0) return new Response(null, { status: 404 });
        if (redis) await redis.del("crud:" + id);
        return new Response(JSON.stringify({
            id, name: b.name, price: b.price, quantity: b.quantity,
        }), { headers: JSON_PLAIN });
    } catch {
        return dbError("update failed");
    }
}

// ── fortunes ────────────────────────────────────────────────────────────────
// The escape is the profile's load-bearing check: row 11 of the seed carries a
// <script> tag and it has to leave here as text.
const RUNTIME_FORTUNE = "Additional fortune added at request time.";
const ESCAPE: Record<string, string> = {
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
};
const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ESCAPE[c]!);

async function fortunes(): Promise<Response> {
    if (!sql) return new Response("DB not available", { status: 500, headers: TEXT });
    try {
        const rows: { id: number; message: string }[] =
            await sql.unsafe("SELECT id, message FROM fortune");
        const all = rows.map((r) => ({ id: r.id, message: r.message }));
        all.push({ id: 0, message: RUNTIME_FORTUNE });
        // Ordinal, not locale aware: the seed carries em-dashes and collation
        // rules would order them in a way the profile does not ask for.
        all.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
        let body = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>" +
            "<tr><th>id</th><th>message</th></tr>";
        for (const f of all) body += `<tr><td>${f.id}</td><td>${escapeHtml(f.message)}</td></tr>`;
        return new Response(body + "</table></body></html>", { headers: HTML });
    } catch {
        return new Response("query failed", { status: 500, headers: TEXT });
    }
}

// The query string, which is the one part of the request the router does not hand over.
const qs = (req: Request): string => {
    const q = req.url.indexOf("?");
    return q < 0 ? "" : req.url.slice(q + 1);
};

// Bun.serve matches method and path itself and fills in req.params, so this entry declares its
// endpoints rather than branching on req.url. `fetch` below is only what is left when nothing
// matched.
const routes = {
    "/pipeline": new Response("ok", { headers: TEXT }),

    "/baseline11": {
        GET: (req: Request) => new Response(String(sumQuery(qs(req))), { headers: TEXT }),
        POST: (req: Request) => baseline11Post(req, sumQuery(qs(req))),
    },

    "/baseline2": (req: Request) => new Response(String(sumQuery(qs(req))), { headers: TEXT }),

    "/json/:count": (req: any) => json(req.params.count, qs(req), req),

    "/upload": { POST: (req: Request) => upload(req) },

    // one segment, so a path with a slash in it never reaches the handler
    "/static/:name": (req: any) => serveStatic(req.params.name, req),

    "/async-db": (req: Request) => asyncDb(qs(req)),

    "/fortunes": () => fortunes(),

    "/crud/items": {
        GET: (req: Request) => crudList(qs(req)),
        POST: (req: Request) => crudCreate(req),
    },

    "/crud/items/:id": {
        GET: (req: any) => crudRead(parseInt(req.params.id, 10)),
        PUT: (req: any) => crudUpdate(req, parseInt(req.params.id, 10)),
    },
};

function handle(): Response {
    return new Response("Not Found", { status: 404, headers: TEXT });
}

const listener = {
    hostname: "0.0.0.0",
    // Every worker process binds the same port and the kernel spreads the accepts,
    // which is how this entry uses more than one core.
    reusePort: true,
    development: false,
    // A 20 MB upload on a saturated server takes longer than the 10s default.
    idleTimeout: 120,
    routes,
    fetch: handle,
};

Bun.serve({ ...listener, port: 8080 });

// json-tls and static-tls: the same routes over TLS on 8081. Bun negotiates
// http/1.1 by default here - there is no h2 to fall into, which is what those
// two profiles require of the ALPN. The harness only mounts /certs for the TLS
// profiles, so without them this listener is simply not opened.
const tlsKey = Bun.file("/certs/server.key");
const tlsCert = Bun.file("/certs/server.crt");
if (await tlsKey.exists() && await tlsCert.exists()) {
    Bun.serve({ ...listener, port: 8081, tls: { key: tlsKey, cert: tlsCert } });
}

console.log("Application started.");
