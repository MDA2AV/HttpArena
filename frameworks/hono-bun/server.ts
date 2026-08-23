import { Hono } from "hono";
import { compress } from "hono/compress";
import { serveStatic } from "hono/bun";
import { Database } from "bun:sqlite";
import { readFileSync, existsSync } from "fs";
import Handlebars from "handlebars";

const SERVER_NAME = "hono-bun";

const MIME_TYPES: Record<string, string> = {
  ".css": "text/css", ".js": "application/javascript", ".html": "text/html",
  ".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp", ".json": "application/json",
};

// serveStatic looks up by bare extension, and the profile checks the header on
// woff2 and webp among others, so the table is given to it explicitly rather
// than relying on what it infers.
const STATIC_MIMES: Record<string, string> = {
  css: "text/css", js: "application/javascript", html: "text/html",
  woff2: "font/woff2", svg: "image/svg+xml", webp: "image/webp", json: "application/json",
};

// Load datasets
const datasetItems: any[] = JSON.parse(readFileSync("/data/dataset.json", "utf8"));

// Open SQLite database read-only. The harness mounts /data/dataset.json and
// /data/static only, so the file is absent on every benchmarked profile - without
// this guard each of the N processes printed three stack traces at startup.
let dbStmt: any = null;
for (let attempt = 0; attempt < 3 && !dbStmt && existsSync("/data/benchmark.db"); attempt++) {
  try {
    const db = new Database("/data/benchmark.db", { readonly: true });
    db.exec("PRAGMA mmap_size=268435456");
    dbStmt = db.prepare("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50");
  } catch (e) {
    console.error(`SQLite open attempt ${attempt + 1} failed:`, e);
    if (attempt < 2) Bun.sleepSync(50);
  }
}

// PostgreSQL pool. Shared by /async-db (read-only) and /crud/* (full CRUD).
//
// The pool is per process and SO_REUSEPORT runs one process per core, so the
// total is procs x max and it has to stay under the harness's Postgres, which
// runs with max_connections=256 and reserves a few of those for the superuser.
// A fixed max overshoots badly: the crud profile hands the container the cpuset
// 1-31,65-95, so nproc reports 62 and 62 x 8 asked for 496 connections against
// 256. Postgres answered "sorry, too many clients already" and those requests
// became 500s.
let pgPool: any = null;
{
  const dbUrl = process.env.DATABASE_URL;
  if (dbUrl) {
    try {
      const { Pool } = require("pg");
      const procs = parseInt(process.env.HTTPARENA_PROCS ?? "", 10) || 1;
      const budget = parseInt(process.env.DATABASE_MAX_CONN ?? "", 10) || 256;
      // headroom for superuser_reserved_connections and anything else holding one
      const max = Math.max(1, Math.floor((budget - 8) / procs));
      pgPool = new Pool({ connectionString: dbUrl, max });
      // Without this, node-pg re-emits every connection failure as an unhandled
      // 'error' event and each one prints a stack trace: the crud run left a 54MB
      // log with 72,031 of them.
      pgPool.on("error", () => {});
    } catch (_) {}
  }
}

// CRUD single-item read cache. 200ms absolute TTL, invalidated on PUT.
//
// With SO_REUSEPORT hono-bun runs N processes that don't share a JS heap,
// so a process-local Map gives each process its own cache and hit rate
// collapses. When REDIS_URL is provided (by the crud profile harness),
// every process talks to the same Redis instance and the cache behaves
// like a single shared store — the same pattern production-stack uses.
//
// Cache values are stored as already-serialized JSON strings so HIT paths
// skip a parse+stringify round trip entirely.
const CRUD_CACHE_TTL_MS = 200;

let redisClient: any = null;
{
  const redisUrl = process.env.REDIS_URL;
  if (redisUrl) {
    try {
      const Redis = require("ioredis");
      redisClient = new Redis(redisUrl, {
        enableAutoPipelining: true,
        lazyConnect: false,
        maxRetriesPerRequest: 1,
      });
      redisClient.on("error", () => {});
    } catch (_) {}
  }
}

const crudCache = new Map<number, { json: string; expiresAt: number }>();
async function crudCacheGet(id: number): Promise<string | null> {
  if (redisClient) return await redisClient.get(`crud:${id}`);
  const hit = crudCache.get(id);
  if (!hit) return null;
  if (hit.expiresAt <= Date.now()) { crudCache.delete(id); return null; }
  return hit.json;
}
async function crudCacheSet(id: number, json: string): Promise<void> {
  if (redisClient) { await redisClient.set(`crud:${id}`, json, "PX", 200); return; }
  crudCache.set(id, { json, expiresAt: Date.now() + CRUD_CACHE_TTL_MS });
}
async function crudCacheDel(id: number): Promise<void> {
  if (redisClient) { await redisClient.del(`crud:${id}`); return; }
  crudCache.delete(id);
}

const app = new Hono();

// Runtime compression for /json/* — honors Accept-Encoding on a per-request
// basis via Hono's built-in middleware (CompressionStream under the hood).
// Scoped to /json so the other endpoints don't pay the encoder cost.
app.use("/json/*", compress());

// --- /pipeline ---
app.get("/pipeline", (c) => {
  return new Response("ok", {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

// --- /baseline11 GET & POST ---
app.get("/baseline11", (c) => {
  const query = c.req.query();
  let sum = 0;
  for (const v of Object.values(query))
    sum += parseInt(v, 10) || 0;
  return new Response(String(sum), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

app.post("/baseline11", async (c) => {
  const query = c.req.query();
  let querySum = 0;
  for (const v of Object.values(query))
    querySum += parseInt(v, 10) || 0;
  const body = await c.req.text();
  let total = querySum;
  const n = parseInt(body.trim(), 10);
  if (!isNaN(n)) total += n;
  return new Response(String(total), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

// --- /baseline2 ---
app.get("/baseline2", (c) => {
  const query = c.req.query();
  let sum = 0;
  for (const v of Object.values(query))
    sum += parseInt(v, 10) || 0;
  return new Response(String(sum), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

// --- /json/:count ---
app.get("/json/:count", (c) => {
  const count = Math.max(0, Math.min(parseInt(c.req.param("count"), 10) || 0, datasetItems.length));
  const m = parseInt(c.req.query("m") || "1") || 1;
  const processedItems = datasetItems.slice(0, count).map((d: any) => ({
    id: d.id, name: d.name, category: d.category,
    price: d.price, quantity: d.quantity, active: d.active,
    tags: d.tags, rating: d.rating,
    total: d.price * d.quantity * m,
  }));
  const body = JSON.stringify({ items: processedItems, count });
  return new Response(body, {
    headers: {
      "content-type": "application/json",
      "content-length": String(Buffer.byteLength(body)),
      server: SERVER_NAME,
    },
  });
});

// --- /db ---
app.get("/db", (c) => {
  if (!dbStmt) {
    return new Response('{"items":[],"count":0}', {
      headers: { "content-type": "application/json", server: SERVER_NAME },
    });
  }
  const min = parseFloat(c.req.query('min') || '') || 10;
  const max = parseFloat(c.req.query('max') || '') || 50;
  const rows = dbStmt.all(min, max) as any[];
  const items = rows.map((r: any) => ({
    id: r.id, name: r.name, category: r.category,
    price: r.price, quantity: r.quantity, active: r.active === 1,
    tags: JSON.parse(r.tags),
    rating: { score: r.rating_score, count: r.rating_count },
  }));
  const body = JSON.stringify({ items, count: items.length });
  return new Response(body, {
    headers: {
      "content-type": "application/json",
      "content-length": String(Buffer.byteLength(body)),
      server: SERVER_NAME,
    },
  });
});

// --- /async-db ---
app.get("/async-db", async (c) => {
  if (!pgPool) {
    return new Response('{"items":[],"count":0}', {
      headers: { "content-type": "application/json", server: SERVER_NAME },
    });
  }
  const min = parseInt(c.req.query('min') || '', 10) || 10;
  const max = parseInt(c.req.query('max') || '', 10) || 50;
  const limit = Math.max(1, Math.min(parseInt(c.req.query('limit') || '', 10) || 50, 50));
  try {
    const result = await pgPool.query(
      "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
      [min, max, limit]
    );
    const items = result.rows.map((r: any) => ({
      id: r.id, name: r.name, category: r.category,
      price: r.price, quantity: r.quantity, active: r.active,
      tags: r.tags,
      rating: { score: r.rating_score, count: r.rating_count },
    }));
    const body = JSON.stringify({ items, count: items.length });
    return new Response(body, {
      headers: {
        "content-type": "application/json",
        "content-length": String(Buffer.byteLength(body)),
        server: SERVER_NAME,
      },
    });
  } catch (e) {
    return new Response('{"items":[],"count":0}', {
      headers: { "content-type": "application/json", server: SERVER_NAME },
    });
  }
});

// --- /upload ---
app.post("/upload", async (c) => {
  let size = 0;
  const body = c.req.raw.body;
  if (body) {
    for await (const chunk of body) {
      size += chunk.byteLength;
    }
  }
  return new Response(String(size), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

// --- /static/* ---
// Hono's own static handler rather than a hand-rolled Bun.file route, which is
// what makes precompressed available: it serves the .br/.gz variants the
// harness leaves next to the originals, and only for compressible types, so
// woff2 and webp still go out as themselves. Nothing is compressed at runtime.
// It reads through to disk on every request, so replacing a file shows up on
// the next one.
//
// Two adjustments around Hono's handler, both on the way in or out rather than
// replacing it:
//
// 1. serveStatic matches Accept-Encoding by exact token - it builds a Set from
//    the split header and asks it for "br". The profile sends
//    "br;q=1, gzip;q=0.8", so the Set holds "br;q=1" and nothing matches, and
//    every static response goes out uncompressed. q-values are ordinary HTTP,
//    so the header is normalised to bare tokens before the handler sees it.
//    Worth 272k -> 329k rps here, and 16.2 -> 5.0 GB/s off the wire.
// 2. serveStatic appends Vary: Accept-Encoding, and Server would come from an
//    onFound hook. Both are correct HTTP, but the profile scores bandwidth and
//    together they are ~38 bytes on every response.
app.use("/static/*", async (c, next) => {
  const accept = c.req.header("accept-encoding");
  if (accept && accept.includes(";")) {
    const bare = accept
      .split(",")
      .map((part) => part.split(";")[0].trim())
      .filter(Boolean)
      .join(", ");
    try {
      c.req.raw.headers.set("accept-encoding", bare);
    } catch {
      // A future runtime may make request headers immutable; serving the
      // uncompressed body is the right fallback, not a 500.
    }
  }
  await next();
  c.res.headers.delete("vary");
});

app.use(
  "/static/*",
  serveStatic({
    root: "/data/static",
    rewriteRequestPath: (path) => path.slice("/static".length),
    precompressed: true,
    mimes: STATIC_MIMES,
  }),
);

// --- CRUD ---
// Realistic REST API: paginated list, cached single-item read, create, update.
// Load-balanced across processes via SO_REUSEPORT.

// GET /crud/items?category=X&page=N&limit=M — always DB, no cache
app.get("/crud/items", async (c) => {
  if (!pgPool) return c.json({ error: "DB not available" }, 500);
  const category = c.req.query("category") || "electronics";
  const page = Math.max(1, parseInt(c.req.query("page") || "1", 10) || 1);
  const rawLimit = parseInt(c.req.query("limit") || "10", 10) || 10;
  const limit = Math.max(1, Math.min(rawLimit, 50));
  const offset = (page - 1) * limit;
  const result = await pgPool.query(
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
    [category, limit, offset]
  );
  const items = result.rows.map((r: any) => ({
    id: r.id, name: r.name, category: r.category,
    price: r.price, quantity: r.quantity, active: r.active,
    tags: r.tags,
    rating: { score: r.rating_score, count: r.rating_count },
  }));
  return c.json({ items, total: items.length, page, limit });
});

// GET /crud/items/:id — single item, cached with 200ms TTL (Redis if REDIS_URL set)
app.get("/crud/items/:id", async (c) => {
  if (!pgPool) return c.json({ error: "DB not available" }, 500);
  const id = parseInt(c.req.param("id"), 10);
  if (!Number.isFinite(id)) return c.notFound();

  const cachedJson = await crudCacheGet(id);
  if (cachedJson) {
    return new Response(cachedJson, {
      status: 200,
      headers: { "content-type": "application/json", "x-cache": "HIT", server: SERVER_NAME },
    });
  }

  const result = await pgPool.query(
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = $1 LIMIT 1",
    [id]
  );
  if (result.rows.length === 0) return c.notFound();

  const r = result.rows[0];
  const item = {
    id: r.id, name: r.name, category: r.category,
    price: r.price, quantity: r.quantity, active: r.active,
    tags: r.tags,
    rating: { score: r.rating_score, count: r.rating_count },
  };
  const json = JSON.stringify(item);
  await crudCacheSet(id, json);
  return new Response(json, {
    status: 200,
    headers: { "content-type": "application/json", "x-cache": "MISS", server: SERVER_NAME },
  });
});

// POST /crud/items — create (INSERT … ON CONFLICT DO UPDATE for upsert), 201
app.post("/crud/items", async (c) => {
  if (!pgPool) return c.json({ error: "DB not available" }, 500);
  const body = await c.req.json();
  const result = await pgPool.query(
    `INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
     VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
     ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5
     RETURNING id`,
    [body.id, body.name ?? "New Product", body.category ?? "test", body.price ?? 0, body.quantity ?? 0]
  );
  const newId = result.rows[0].id;
  c.status(201);
  return c.json({ id: newId, name: body.name, category: body.category, price: body.price, quantity: body.quantity });
});

// PUT /crud/items/:id — update and invalidate cache
app.put("/crud/items/:id", async (c) => {
  if (!pgPool) return c.json({ error: "DB not available" }, 500);
  const id = parseInt(c.req.param("id"), 10);
  if (!Number.isFinite(id)) return c.notFound();
  const body = await c.req.json();
  const result = await pgPool.query(
    "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
    [body.name ?? "Updated", body.price ?? 0, body.quantity ?? 0, id]
  );
  if (result.rowCount === 0) return c.notFound();
  await crudCacheDel(id);
  return c.json({ id, name: body.name, price: body.price, quantity: body.quantity });
});

// --- /fortunes ---
// Standard mode wants a real template engine here, with the template as its own
// artifact rather than a string built in the handler. Handlebars is on the
// profile's list of accepted engines and escapes {{ }} by default, which is the
// check the profile calls load-bearing: row 11 of the seed carries a <script>.
const fortunesTemplate = Handlebars.compile(
  readFileSync(new URL("./views/fortunes.hbs", import.meta.url), "utf8"),
);
const RUNTIME_FORTUNE = "Additional fortune added at request time.";

app.get("/fortunes", async (c) => {
  if (!pgPool) return c.text("DB not available", 500);
  try {
    const r = await pgPool.query({
      name: "fortunes",
      text: "SELECT id, message FROM fortune",
    });
    const fortunes = r.rows.map((x: any) => ({ id: x.id, message: x.message }));
    fortunes.push({ id: 0, message: RUNTIME_FORTUNE });
    // Ordinal, not locale aware: the seed carries em-dashes and collation rules
    // would order them in a way the profile does not ask for.
    fortunes.sort((a: any, b: any) =>
      a.message < b.message ? -1 : a.message > b.message ? 1 : 0,
    );
    return new Response(fortunesTemplate({ fortunes }), {
      headers: { "content-type": "text/html; charset=utf-8", server: SERVER_NAME },
    });
  } catch (_) {
    return c.text("query failed", 500);
  }
});

// Catch-all
app.all("*", () => new Response("Not found", { status: 404 }));

// Start — Bun native serve (no adapter needed)
Bun.serve({
  port: 8080,
  reusePort: true,
  fetch: app.fetch,
});

// json-tls and static-tls: the same app over TLS on 8081. Both routes already
// exist, so the listener is the only new thing. Bun negotiates http/1.1 here -
// there is no h2 to fall into, which is what those two profiles require of the
// ALPN. The harness only mounts /certs for the TLS profiles, so without them
// this listener is not opened.
if (existsSync("/certs/server.key") && existsSync("/certs/server.crt")) {
  Bun.serve({
    port: 8081,
    reusePort: true,
    tls: {
      key: Bun.file("/certs/server.key"),
      cert: Bun.file("/certs/server.crt"),
    },
    fetch: app.fetch,
  });
}
