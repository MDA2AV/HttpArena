const zlib = require("zlib");
const fs = require("fs");

const MIME_TYPES: Record<string, string> = {
  ".css": "text/css", ".js": "application/javascript", ".html": "text/html",
  ".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp", ".json": "application/json",
};

// Pre-load dataset
const data = JSON.parse(fs.readFileSync("/data/dataset.json", "utf8"));
const items = data.map((d: any) => ({
  id: d.id, name: d.name, category: d.category,
  price: d.price, quantity: d.quantity, active: d.active,
  tags: d.tags, rating: d.rating,
  total: Math.round(d.price * d.quantity * 100) / 100,
}));
const jsonResponseBuf = Buffer.from(JSON.stringify({ items, count: items.length }));

// Pre-load large dataset for /compression endpoint (compressed per-request)
const largeData = JSON.parse(fs.readFileSync("/data/dataset-large.json", "utf8"));
const largeItems = largeData.map((d: any) => ({
  id: d.id, name: d.name, category: d.category,
  price: d.price, quantity: d.quantity, active: d.active,
  tags: d.tags, rating: d.rating,
  total: Math.round(d.price * d.quantity * 100) / 100,
}));
const largeJsonBuf = Buffer.from(JSON.stringify({ items: largeItems, count: largeItems.length }));

// Pre-load static files
const staticFiles: Record<string, { buf: Buffer; ct: string }> = {};
try {
  for (const name of fs.readdirSync("/data/static")) {
    const buf = fs.readFileSync(`/data/static/${name}`);
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

function handleRequest(req: Request): Response | Promise<Response> {
  const url = req.url;
  const protoEnd = url.indexOf("//") + 2;
  const pathStart = url.indexOf("/", protoEnd);
  const qIdx = url.indexOf("?", pathStart);
  const path = qIdx === -1 ? url.slice(pathStart) : url.slice(pathStart, qIdx);

  if (path === "/pipeline") {
    return new Response("ok", { headers: { "content-type": "text/plain" } });
  }

  if (path === "/json") {
    return new Response(jsonResponseBuf, {
      headers: { "content-type": "application/json", "content-length": String(jsonResponseBuf.length) },
    });
  }

  if (path === "/compression") {
    const compressed = Bun.gzipSync(largeJsonBuf, { level: 1 });
    return new Response(compressed, {
      headers: {
        "content-type": "application/json",
        "content-encoding": "gzip",
        "content-length": String(compressed.length),
      },
    });
  }

  if (path === "/baseline2") {
    const body = String(sumQuery(url));
    return new Response(body, { headers: { "content-type": "text/plain" } });
  }

  if (path.startsWith("/static/")) {
    const name = path.slice(8);
    const sf = staticFiles[name];
    if (sf) {
      return new Response(sf.buf, {
        headers: { "content-type": sf.ct, "content-length": String(sf.buf.length) },
      });
    }
    return new Response("Not found", { status: 404 });
  }

  if (path === "/upload" && req.method === "POST") {
    return req.arrayBuffer().then((ab) => {
      const buf = Buffer.from(ab);
      const c = zlib.crc32(buf);
      return new Response((c >>> 0).toString(16).padStart(8, "0"), {
        headers: { "content-type": "text/plain" },
      });
    });
  }

  // /baseline11 — GET or POST
  const querySum = sumQuery(url);
  if (req.method === "POST") {
    return req.text().then((body) => {
      let total = querySum;
      const n = parseInt(body.trim(), 10);
      if (!isNaN(n)) total += n;
      return new Response(String(total), { headers: { "content-type": "text/plain" } });
    });
  }

  return new Response(String(querySum), { headers: { "content-type": "text/plain" } });
}

// Read TLS certs
let tlsOptions: { cert: string; key: string } | undefined;
try {
  tlsOptions = {
    cert: fs.readFileSync("/certs/server.crt", "utf8"),
    key: fs.readFileSync("/certs/server.key", "utf8"),
  };
} catch (_) {}

// HTTP server on port 8080
Bun.serve({
  port: 8080,
  fetch: handleRequest,
  reusePort: true,
});

// HTTPS/H2 server on port 8443
if (tlsOptions) {
  Bun.serve({
    port: 8443,
    tls: tlsOptions,
    fetch: handleRequest,
    reusePort: true,
  });
}
