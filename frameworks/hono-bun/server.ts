import { Hono } from "hono";
import { Database } from "bun:sqlite";
import { readFileSync, readdirSync } from "fs";

const SERVER_NAME = "hono-bun";

const MIME_TYPES: Record<string, string> = {
  ".css": "text/css", ".js": "application/javascript", ".html": "text/html",
  ".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp", ".json": "application/json",
};

// Load datasets
const datasetItems: any[] = JSON.parse(readFileSync("/data/dataset.json", "utf8"));

const largeDatasetItems: any[] = JSON.parse(readFileSync("/data/dataset-large.json", "utf8"));

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

// Pre-load static files
const staticFiles: Record<string, { buf: Buffer; ct: string }> = {};
try {
  for (const name of readdirSync("/data/static")) {
    const buf = readFileSync(`/data/static/${name}`);
    const ext = name.slice(name.lastIndexOf("."));
    staticFiles[name] = { buf: Buffer.from(buf), ct: MIME_TYPES[ext] || "application/octet-stream" };
  }
} catch (_) {}

function sumQuery(url: string): number {
  const q = url.indexOf("?");
  if (q === -1) return 0;
  let sum = 0;
  const qs = url.slice(q + 1);
  let i = 0;
  while (i < qs.length) {
    const eq = qs.indexOf("=", i);
    if (eq === -1) break;
    let amp = qs.indexOf("&", eq);
    if (amp === -1) amp = qs.length;
    const n = parseInt(qs.slice(eq + 1, amp), 10);
    if (!isNaN(n)) sum += n;
    i = amp + 1;
  }
  return sum;
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
  const s = sumQuery(c.req.raw.url);
  return new Response(String(s), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

app.post("/baseline11", async (c) => {
  const querySum = sumQuery(c.req.raw.url);
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
  const s = sumQuery(c.req.raw.url);
  return new Response(String(s), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

// --- /json ---
app.get("/json", (c) => {
  return new Response(smallPayload, {
    headers: {
      "content-type": "application/json",
      "content-length": String(smallPayload.length),
      server: SERVER_NAME,
    },
  });
});

// --- /compression ---
app.get("/compression", (c) => {
  const gz = Buffer.from(Bun.gzipSync(largeJsonBuf, { level: 1 }));
  return new Response(gz, {
    headers: {
      "content-type": "application/json",
      "content-encoding": "gzip",
      "content-length": String(gz.length),
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
  let min = 10, max = 50;
  const url = c.req.raw.url;
  const qIdx = url.indexOf("?");
  if (qIdx !== -1) {
    const qs = url.slice(qIdx + 1);
    for (const pair of qs.split("&")) {
      const eq = pair.indexOf("=");
      if (eq === -1) continue;
      const k = pair.slice(0, eq), v = pair.slice(eq + 1);
      if (k === "min") min = parseFloat(v) || 10;
      else if (k === "max") max = parseFloat(v) || 50;
    }
  }
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

// --- /upload ---
app.post("/upload", async (c) => {
  const ab = await c.req.arrayBuffer();
  return new Response(String(ab.byteLength), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

// --- /static/:filename ---
app.get("/static/:filename", (c) => {
  const filename = c.req.param("filename");
  const sf = staticFiles[filename];
  if (sf) {
    return new Response(sf.buf, {
      headers: {
        "content-type": sf.ct,
        "content-length": String(sf.buf.length),
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
gth });
  return new Response(body, {
    headers: {
      "content-type": "application/json",
      "content-length": String(Buffer.byteLength(body)),
      server: SERVER_NAME,
    },
  });
});

// --- /upload ---
app.post("/upload", async (c) => {
  const ab = await c.req.arrayBuffer();
  return new Response(String(ab.byteLength), {
    headers: { "content-type": "text/plain", server: SERVER_NAME },
  });
});

// --- /static/:filename ---
app.get("/static/:filename", (c) => {
  const filename = c.req.param("filename");
  const sf = staticFiles[filename];
  if (sf) {
    return new Response(sf.buf, {
      headers: {
        "content-type": sf.ct,
        "content-length": String(sf.buf.length),
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
pp.fetch,
});
