// Deno.serve with nothing on top of it. The default export is the shape
// `deno serve` expects; --parallel in the Dockerfile then runs one process per
// core, each binding 8080 with SO_REUSEPORT, so no cluster module is involved
// and there is no worker bookkeeping in here.

// Deno ships no Postgres or Redis client, so the database profiles bring the two
// drivers in over npm: specifiers. Nothing else is on top - still no framework
// and still no router.
import pg from "npm:pg@8";
import Redis from "npm:ioredis@5";

interface Item {
  id: number;
  name: string;
  category: string;
  price: number;
  quantity: number;
  active: boolean;
  tags: string[];
  rating: { score: number; count: number };
}

// The dataset is only mounted for the json profiles, so a missing file serves
// an empty list instead of taking the process down on the other profiles.
let datasetItems: Item[] = [];
try {
  datasetItems = JSON.parse(
    Deno.readTextFileSync(Deno.env.get("DATASET_PATH") ?? "/data/dataset.json"),
  );
} catch (_) { /* no dataset mounted */ }

const TEXT_HEADERS = { "content-type": "text/plain", "server": "deno" };
const HTML_HEADERS = { "content-type": "text/html; charset=utf-8", "server": "deno" };
const JSON_HEADERS = { "content-type": "application/json", "server": "deno" };
const JSON_GZIP_HEADERS = {
  ...JSON_HEADERS,
  "content-encoding": "gzip",
  "vary": "accept-encoding",
};

// Only wired for the profiles that use them, so both stay null otherwise and the
// handlers answer without touching them. The pool is per process and `deno serve
// --parallel` runs one per core, so the harness's DATABASE_MAX_CONN is split
// across them rather than opened by each.
const dbUrl = Deno.env.get("DATABASE_URL");
const redisUrl = Deno.env.get("REDIS_URL");
const workers = (() => {
  try {
    const [quota, period] = Deno.readTextFileSync("/sys/fs/cgroup/cpu.max").trim().split(" ");
    if (quota !== "max") {
      const n = Math.floor(Number(quota) / Number(period));
      if (n >= 1) return n;
    }
  } catch (_) { /* no cgroup limit */ }
  return navigator.hardwareConcurrency || 1;
})();

const pgPool = dbUrl
  ? new pg.Pool({
    connectionString: dbUrl,
    max: Math.max(1, Math.floor(
      (parseInt(Deno.env.get("DATABASE_MAX_CONN") ?? "256", 10) || 256) / workers)),
  })
  : null;
pgPool?.on("error", () => {});
const redis = redisUrl ? new Redis(redisUrl, { enableAutoPipelining: true }) : null;
redis?.on("error", () => {});

const ITEM_COLUMNS =
  "id, name, category, price, quantity, active, tags, rating_score, rating_count";
// deno-lint-ignore no-explicit-any
const itemShape = (r: any) => ({
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
    if (n === n) sum += n;
  }
  return sum;
}

function queryValue(query: string, name: string): string {
  for (const pair of query.split("&")) {
    if (pair.startsWith(name) && pair[name.length] === "=") {
      return pair.slice(name.length + 1);
    }
  }
  return "";
}

// ── static ──────────────────────────────────────────────────────────────────
// Content-Type from an explicit table: the profile checks the header on woff2
// and webp among others. Deno.open + the file's readable stream sends the bytes
// off disk per request with nothing retained between them, which is what the
// profile requires of a framework entry. This entry is `standard`, so the .br
// and .gz files beside the originals are left alone - hand-rolled suffix lookup
// is a tuned technique and Deno.serve has no static handler to negotiate them.
const MIME: Record<string, string> = {
  css: "text/css", js: "text/javascript", html: "text/html",
  woff2: "font/woff2", svg: "image/svg+xml", webp: "image/webp",
  json: "application/json",
};

async function serveStatic(path: string): Promise<Response> {
  const name = path.slice(8);
  if (!name || name.includes("/") || name.includes("..")) {
    return new Response("Not found", { status: 404, headers: TEXT_HEADERS });
  }
  try {
    const file = await Deno.open("/data/static/" + name, { read: true });
    // Size off the open handle rather than a second path lookup, so the response
    // carries a Content-Length and the body is not chunk-framed.
    const size = (await file.stat()).size;
    const dot = name.lastIndexOf(".");
    const type = (dot > 0 ? MIME[name.slice(dot + 1)] : undefined) ??
      "application/octet-stream";
    return new Response(file.readable, {
      headers: {
        "content-type": type,
        "content-length": String(size),
        "server": "deno",
      },
    });
  } catch (_) {
    return new Response("Not found", { status: 404, headers: TEXT_HEADERS });
  }
}

// ── database ────────────────────────────────────────────────────────────────
const EMPTY_ITEMS = '{"items":[],"count":0}';
const intParam = (query: string, key: string, dflt: number) => {
  const n = parseInt(queryValue(query, key), 10);
  return n === n ? n : dflt;
};
const dbError = (msg: string, status = 500) =>
  new Response(`{"error":"${msg}"}`, { status, headers: JSON_HEADERS });

async function asyncDb(query: string): Promise<Response> {
  if (!pgPool) return new Response(EMPTY_ITEMS, { headers: JSON_HEADERS });
  const min = intParam(query, "min", 10), max = intParam(query, "max", 50);
  let limit = intParam(query, "limit", 50);
  if (limit < 1) limit = 1;
  if (limit > 50) limit = 50;
  try {
    // Named, so pg prepares it once per connection and later executions skip the
    // parse; the parameterized form alone re-parses on every call.
    const r = await pgPool.query({
      name: "items-by-price",
      text: `SELECT ${ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3`,
      values: [min, max, limit],
    });
    const items = r.rows.map(itemShape);
    return new Response(JSON.stringify({ items, count: items.length }),
      { headers: JSON_HEADERS });
  } catch (_) {
    return new Response(EMPTY_ITEMS, { headers: JSON_HEADERS });
  }
}

async function crudList(query: string): Promise<Response> {
  if (!pgPool) return dbError("DB not available");
  const category = queryValue(query, "category") || "electronics";
  const page = Math.max(1, intParam(query, "page", 1));
  let limit = intParam(query, "limit", 10);
  if (limit < 1) limit = 1;
  if (limit > 50) limit = 50;
  try {
    const r = await pgPool.query({
      name: "crud-list",
      text: `SELECT ${ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3`,
      values: [category, limit, (page - 1) * limit],
    });
    const items = r.rows.map(itemShape);
    return new Response(JSON.stringify({ items, total: items.length, page, limit }),
      { headers: JSON_HEADERS });
  } catch (_) {
    return dbError("query failed");
  }
}

// Cache-aside on Redis where the harness provides it - crud is the one profile
// that does, and it is shared across the parallel processes as a per-process map
// would not be.
const CRUD_TTL_MS = 200;

async function crudRead(id: number): Promise<Response> {
  if (!pgPool) return dbError("DB not available");
  if (id !== id) return new Response(null, { status: 404 });
  try {
    if (redis) {
      const hit = await redis.get("crud:" + id);
      if (hit) {
        return new Response(hit, { headers: { ...JSON_HEADERS, "x-cache": "HIT" } });
      }
    }
    const r = await pgPool.query({
      name: "crud-read",
      text: `SELECT ${ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1`,
      values: [id],
    });
    if (r.rows.length === 0) return new Response(null, { status: 404 });
    const body = JSON.stringify(itemShape(r.rows[0]));
    if (redis) redis.set("crud:" + id, body, "PX", CRUD_TTL_MS);
    return new Response(body, { headers: { ...JSON_HEADERS, "x-cache": "MISS" } });
  } catch (_) {
    return dbError("query failed");
  }
}

async function crudCreate(req: Request): Promise<Response> {
  if (!pgPool) return dbError("DB not available");
  try {
    // deno-lint-ignore no-explicit-any
    const b: any = await req.json();
    const r = await pgPool.query({
      name: "crud-create",
      text: "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
        `VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0) ` +
        "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id",
      values: [b.id, b.name ?? "New Product", b.category ?? "test", b.price ?? 0, b.quantity ?? 0],
    });
    return new Response(JSON.stringify({
      id: r.rows[0].id, name: b.name, category: b.category,
      price: b.price, quantity: b.quantity,
    }), { status: 201, headers: JSON_HEADERS });
  } catch (_) {
    return dbError("insert failed");
  }
}

async function crudUpdate(req: Request, id: number): Promise<Response> {
  if (!pgPool) return dbError("DB not available");
  if (id !== id) return new Response(null, { status: 404 });
  try {
    // deno-lint-ignore no-explicit-any
    const b: any = await req.json();
    const r = await pgPool.query({
      name: "crud-update",
      text: "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
      values: [b.name ?? "Updated", b.price ?? 0, b.quantity ?? 0, id],
    });
    if (r.rowCount === 0) return new Response(null, { status: 404 });
    if (redis) await redis.del("crud:" + id);
    return new Response(JSON.stringify({
      id, name: b.name, price: b.price, quantity: b.quantity,
    }), { headers: JSON_HEADERS });
  } catch (_) {
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
const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ESCAPE[c]);

async function fortunes(): Promise<Response> {
  if (!pgPool) {
    return new Response("DB not available", { status: 500, headers: TEXT_HEADERS });
  }
  try {
    const r = await pgPool.query({ name: "fortunes", text: "SELECT id, message FROM fortune" });
    // deno-lint-ignore no-explicit-any
    const all = r.rows.map((x: any) => ({ id: x.id, message: x.message }));
    all.push({ id: 0, message: RUNTIME_FORTUNE });
    // Ordinal, not locale aware: the seed carries em-dashes and collation rules
    // would order them in a way the profile does not ask for.
    all.sort((a: { message: string }, b: { message: string }) =>
      a.message < b.message ? -1 : a.message > b.message ? 1 : 0);
    let body = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>" +
      "<tr><th>id</th><th>message</th></tr>";
    for (const f of all) {
      body += `<tr><td>${f.id}</td><td>${escapeHtml(f.message)}</td></tr>`;
    }
    return new Response(body + "</table></body></html>", { headers: HTML_HEADERS });
  } catch (_) {
    return new Response("query failed", { status: 500, headers: TEXT_HEADERS });
  }
}

async function handle(req: Request): Promise<Response> {
    // req.url is absolute, so the path starts at the first "/" after the
    // authority. Slicing it beats `new URL()` per request, and the routing
    // below is a handful of paths that need no matcher.
    const url = req.url;
    const start = url.indexOf("/", 8);
    const mark = url.indexOf("?", start);
    const path = mark < 0 ? url.slice(start) : url.slice(start, mark);
    const query = mark < 0 ? "" : url.slice(mark + 1);

    if (path === "/pipeline") {
      return new Response("ok", { headers: TEXT_HEADERS });
    }

    if (path === "/baseline11") {
      let total = sumQuery(query);
      if (req.method === "POST") {
        const n = parseInt((await req.text()).trim(), 10);
        if (n === n) total += n;
      }
      return new Response(String(total), { headers: TEXT_HEADERS });
    }

    if (path.startsWith("/json/")) {
      let count = parseInt(path.slice(6), 10) || 0;
      if (count < 0) count = 0;
      if (count > datasetItems.length) count = datasetItems.length;
      const m = parseInt(queryValue(query, "m"), 10) || 1;
      const items = datasetItems.slice(0, count).map((d) => ({
        id: d.id,
        name: d.name,
        category: d.category,
        price: d.price,
        quantity: d.quantity,
        active: d.active,
        tags: d.tags,
        rating: d.rating,
        total: d.price * d.quantity * m,
      }));
      const body = JSON.stringify({ items, count });
      // json-comp. Deno.serve does not negotiate encodings for you, so
      // the check is here, per request. CompressionStream is the only
      // compressor the runtime ships, hence gzip and not brotli.
      if (req.headers.get("accept-encoding")?.includes("gzip")) {
        const gzip = new Response(body).body!
          .pipeThrough(new CompressionStream("gzip"));
        return new Response(gzip, { headers: JSON_GZIP_HEADERS });
      }
      return new Response(body, { headers: JSON_HEADERS });
    }

    if (path === "/upload" && req.method === "POST") {
      let size = 0;
      if (req.body) {
        for await (const chunk of req.body) size += chunk.byteLength;
      }
      return new Response(String(size), { headers: TEXT_HEADERS });
    }

    if (path.startsWith("/static/")) return await serveStatic(path);

    if (path === "/async-db") return await asyncDb(query);

    if (path === "/fortunes") return await fortunes();

    if (path === "/crud/items") {
      if (req.method === "POST") return await crudCreate(req);
      return await crudList(query);
    }
    if (path.startsWith("/crud/items/")) {
      const id = parseInt(path.slice(12), 10);
      if (req.method === "PUT") return await crudUpdate(req, id);
      return await crudRead(id);
    }

    return new Response("Not found", { status: 404, headers: TEXT_HEADERS });
}

// json-tls and static-tls: the same routes over TLS on 8081. Deno advertises no
// ALPN protocol unless asked, so an HTTP/1.1 client negotiates plain http/1.1
// and never sees an h2 offer - which is what those two profiles require. The
// harness only mounts /certs for the TLS profiles, so without them this listener
// is simply not opened. reusePort matches the plaintext side: `deno serve
// --parallel` loads this module once per process and each binds 8081 itself.
try {
  const cert = Deno.readTextFileSync(Deno.env.get("TLS_CERT") ?? "/certs/server.crt");
  const key = Deno.readTextFileSync(Deno.env.get("TLS_KEY") ?? "/certs/server.key");
  Deno.serve({ port: 8081, hostname: "0.0.0.0", reusePort: true, cert, key,
    onListen: () => {} }, handle);
} catch (_) { /* no certs mounted: plaintext profiles only */ }

// The shape `deno serve` expects; --parallel in the Dockerfile then runs one
// process per core, each binding 8080 with SO_REUSEPORT.
export default { fetch: handle };
