import { Hono } from "hono";
import { Database } from "bun:sqlite";
import { readFileSync } from "fs";

const SERVER_NAME = "hono-bun";

const MIME_TYPES: Record<string, string> = {
  ".css": "text/css", ".js": "application/javascript", ".html": "text/html",
  ".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp", ".json": "application/json",
};

// Load datasets
const datasetItems: any[] = JSON.parse(readFileSync("/data/dataset.json", "utf8"));

// Open SQLite database read-only
let dbStmt: any = null;
for (let attempt = 0; attempt < 3 && !dbStmt; attempt++) {
  try {
    const db = new Database("/data/benchmark.db", { readonly: true });
    db.exec("PRAGMA mmap_size=268435456");
    dbStmt = db.prepare("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50");
  } catch (e) {
    console.error(`SQLite open attempt ${attempt + 1} failed:`, e);
    if (attempt < 2) Bun.sleepSync(50);
  }
}

// PostgreSQL pool for async-db
let pgPool: any = null;
{
  const dbUrl = process.env.DATABASE_URL;
  if (dbUrl) {
    try {
      const { Pool } = require("pg");
      pgPool = new Pool({ connectionString: dbUrl, max: 4 });
    } catch (_) {}
  }
}

const app = new Hono();

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

// --- /static/:filename ---
app.get("/static/:filename", async (c) => {
  const filename = c.req.param("filename");
  const file = Bun.file(`/data/static/${filename}`);
  if (await file.exists()) {
    const ext = filename.slice(filename.lastIndexOf("."));
    return new Response(file, {
      headers: {
        "content-type": MIME_TYPES[ext] || "application/octet-stream",
        server: SERVER_NAME,
      },
    });
  }
  return new Response("Not found", { status: 404 });
});

// Catch-all
app.all("*", () => new Response("Not found", { status: 404 }));

// Start — Bun native serve (no adapter needed)
Bun.serve({
  port: 8080,
  reusePort: true,
  fetch: app.fetch,
});
