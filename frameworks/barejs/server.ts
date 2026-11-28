import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import { SQL } from "bun";
import Handlebars from "handlebars";
import { BareJS, compress, staticFile, type Context } from "barejs";

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

type DatabaseItem = Omit<Item, "rating"> & {
  tags: string[] | unknown;
  rating_score: number;
  rating_count: number;
};

type Fortune = { id: number; message: string };

function cpuCount(): number {
  try {
    const [quota, period] = readFileSync("/sys/fs/cgroup/cpu.max", "utf8").trim().split(" ");
    if (quota !== "max") {
      const limited = Math.floor(Number(quota) / Number(period));
      if (limited >= 1) return limited;
    }
  } catch {}
  return os.availableParallelism ? os.availableParallelism() : os.cpus().length;
}

function loadDataset(): Item[] {
  try {
    const raw = readFileSync(process.env.DATASET_PATH || "/data/dataset.json", "utf8");
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as Item[]) : [];
  } catch {
    return [];
  }
}

function integer(value: string | null | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function sumQuery(query: Record<string, string>): number {
  let sum = 0;
  for (const key in query) {
    const parsed = Number.parseInt(query[key]!, 10);
    if (Number.isFinite(parsed)) sum += parsed;
  }
  return sum;
}

const ITEM_COLUMNS =
  "id, name, category, price, quantity, active, tags, rating_score, rating_count";

function itemFromDatabase(row: DatabaseItem): Item {
  return {
    id: row.id,
    name: row.name,
    category: row.category,
    price: row.price,
    quantity: row.quantity,
    active: row.active,
    tags: row.tags as string[],
    rating: { score: row.rating_score, count: row.rating_count },
  };
}

const STATIC_MIME: Record<string, string> = {
  css: "text/css",
  js: "application/javascript",
  html: "text/html",
  woff2: "font/woff2",
  svg: "image/svg+xml",
  webp: "image/webp",
  json: "application/json",
};

function pickPrecompressedEncoding(accept: string | null): "br" | "gzip" | null {
  if (!accept) return null;
  for (const part of accept.split(",")) {
    const [name, ...params] = part.trim().split(";");
    const enc = name!.trim().toLowerCase();
    if (enc !== "br" && enc !== "gzip") continue;
    const q = params.find((p) => p.trim().startsWith("q="));
    if (q && Number.parseFloat(q.trim().slice(2)) <= 0) continue;
    return enc;
  }
  return null;
}

function buildApp() {
  const dataset = loadDataset();
  const workerCount = Math.max(1, integer(process.env.BARE_WORKERS, cpuCount()));
  const totalMax = Math.min(integer(process.env.DATABASE_MAX_CONN, 256) || 256, 240);
  const perWorker = Math.max(1, Math.floor(totalMax / workerCount));
  const databaseUrl = process.env.DATABASE_URL;
  const sql = databaseUrl ? new SQL({ url: databaseUrl, max: perWorker }) : undefined;
  sql?.connect().catch(() => {});

  const fortunesSource = readFileSync("/app/views/fortunes.hbs", "utf8");
  const renderFortunes = Handlebars.compile(fortunesSource);
  const RUNTIME_FORTUNE = "Additional fortune added at request time.";

  // Built-in BareJS static file handler (etag + disk validation per request)
  const bareStatic = staticFile("/data/static", { etag: false });

  const serveStatic = async (ctx: Context) => {
    const name = ctx.params.name || "";
    if (name.length === 0 || name.includes("/") || name.includes("..")) {
      return new Response("Not Found", { status: 404, headers: { "content-type": "text/plain" } });
    }

    // Standard rule allows selecting pre-compressed .br/.gz variants on disk off Accept-Encoding
    const encoding = pickPrecompressedEncoding(ctx.req.headers.get("accept-encoding"));
    if (encoding) {
      const encoded = Bun.file(`/data/static/${name}${encoding === "br" ? ".br" : ".gz"}`);
      if (await encoded.exists()) {
        const dot = name.lastIndexOf(".");
        const type =
          (dot > 0 && STATIC_MIME[name.slice(dot + 1)]) || "application/octet-stream";
        return new Response(encoded, {
          headers: { "content-type": type, "content-encoding": encoding },
        });
      }
    }

    // Rewrite path prefix /static/foo -> /foo for BareJS staticFile("/data/static")
    const origUrl = ctx.req.url;
    const idx = origUrl.indexOf("/static/");
    if (idx !== -1) {
      const rewritten = origUrl.slice(0, idx) + origUrl.slice(idx + 7);
      ctx.req = new Request(rewritten, ctx.req);
    }
    const res = await bareStatic(ctx, () =>
      new Response("Not Found", { status: 404, headers: { "content-type": "text/plain" } }),
    );
    return res;
  };

  const jsonHandler = (ctx: Context) => {
    const count = Math.min(Math.max(0, integer(ctx.params.count, 0)), dataset.length);
    const m = integer(ctx.query.m, 1) || 1;
    const items = new Array<Item & { total: number }>(count);
    for (let i = 0; i < count; i++) {
      const d = dataset[i]!;
      items[i] = {
        id: d.id,
        name: d.name,
        category: d.category,
        price: d.price,
        quantity: d.quantity,
        active: d.active,
        tags: d.tags,
        rating: d.rating,
        total: d.price * d.quantity * m,
      };
    }
    return { items, count };
  };

  const echoHandler = async (ctx: Context) => {
    const buf = await ctx.req.arrayBuffer();
    return new Response(buf, {
      headers: { "content-type": "application/octet-stream" },
    });
  };

  const specHeadersHandler = async (ctx: Context) => {
    if (ctx.req.method === "POST") {
      await ctx.req.arrayBuffer();
    }
    let out = "";
    ctx.req.headers.forEach((value, name) => {
      out += `${name}: ${value}\n`;
    });
    return out;
  };

  const app = new BareJS();

  app.get("/pipeline", () => "ok");

  app.get("/delay/:ms", async (ctx: Context) => {
    const ms = Math.max(0, integer(ctx.params.ms, 0));
    if (ms > 0) await Bun.sleep(ms);
    return String(ms);
  });

  app.get("/baseline11", (ctx: Context) => String(sumQuery(ctx.query)));

  app.post("/baseline11", async (ctx: Context) => {
    const text = (await ctx.req.text()).trim();
    const n = Number.parseInt(text, 10);
    const total = sumQuery(ctx.query) + (Number.isFinite(n) ? n : 0);
    return String(total);
  });

  app.get("/baseline2", (ctx: Context) => String(sumQuery(ctx.query)));

  // Built-in BareJS compression middleware scoped to /json/:count
  app.get(
    "/json/:count",
    compress({ encodings: ["br", "gzip"], level: 4 }),
    jsonHandler,
  );

  app.post("/echo", echoHandler);

  app.get("/static/:name", serveStatic);

  app.get("/async-db", async (ctx: Context) => {
    if (!sql) return { items: [], count: 0 };
    const min = integer(ctx.query.min, 10);
    const max = integer(ctx.query.max, 50);
    const limit = Math.min(50, Math.max(1, integer(ctx.query.limit, 50)));
    try {
      const rows: DatabaseItem[] =
        await sql`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ${min} AND ${max} LIMIT ${limit}`;
      const items = rows.map(itemFromDatabase);
      return { items, count: items.length };
    } catch {
      return { items: [], count: 0 };
    }
  });

  app.get("/fortunes", async () => {
    if (!sql) {
      return new Response("DB not available", {
        status: 500,
        headers: { "content-type": "text/plain" },
      });
    }
    try {
      const rows: Fortune[] = await sql`SELECT id, message FROM fortune`;
      const fortunes = rows.map((r) => ({ id: r.id, message: r.message }));
      fortunes.push({ id: 0, message: RUNTIME_FORTUNE });
      fortunes.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0));
      return new Response(renderFortunes({ fortunes }), {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    } catch {
      return new Response("query failed", {
        status: 500,
        headers: { "content-type": "text/plain" },
      });
    }
  });

  // Compliance route (/spec)
  app.get("/spec", () => "spec ok");
  app.head("/spec", () => new Response(null, { status: 200, headers: { "content-type": "text/plain" } }));
  app.options("/spec", async (ctx: Context) => {
    await ctx.req.arrayBuffer();
    return new Response(null, {
      status: 200,
      headers: { allow: "GET, HEAD, POST, OPTIONS" },
    });
  });
  app.post("/spec", echoHandler);
  app.get("/spec/headers", specHeadersHandler);
  app.post("/spec/headers", specHeadersHandler);

  // Native BareJS WebSocket route (/ws)
  app.ws("/ws", {
    message(ws, message) {
      ws.send(message);
    },
  });

  app.compile();
  return app;
}

function runWorker(): void {
  const app = buildApp();

  // Primary HTTP/1.1 + WebSocket listener on :8080 via BareJS app.listen()
  app.listen(8080, "0.0.0.0", true, { maxRequestBodySize: 128 * 1024 * 1024 });

  type ServeOpts = Bun.Serve.Options<undefined> & { http2?: boolean; http3?: boolean };
  const serveExtra = (opts: ServeOpts) => {
    try {
      Bun.serve(opts);
    } catch {}
  };

  // HTTP/2 cleartext (h2c) on :8082
  serveExtra({
    port: 8082,
    hostname: "0.0.0.0",
    reusePort: true,
    development: false,
    idleTimeout: 120,
    maxRequestBodySize: 128 * 1024 * 1024,
    http2: true,
    fetch: (req) => app.fetch(req),
  });

  // TLS listeners when /certs are mounted by the harness
  if (existsSync("/certs/server.key") && existsSync("/certs/server.crt")) {
    const tls = {
      key: Bun.file("/certs/server.key"),
      cert: Bun.file("/certs/server.crt"),
    };

    // HTTP/1.1 over TLS on :8081 (json-tls, static-tls, 8gbit, connections-1m-tls)
    serveExtra({
      port: 8081,
      hostname: "0.0.0.0",
      reusePort: true,
      development: false,
      idleTimeout: 120,
      maxRequestBodySize: 128 * 1024 * 1024,
      tls,
      fetch: (req) => app.fetch(req),
    });

    // HTTP/2 + HTTP/3 over TLS/QUIC on :8443
    serveExtra({
      port: 8443,
      hostname: "0.0.0.0",
      reusePort: true,
      development: false,
      idleTimeout: 120,
      maxRequestBodySize: 128 * 1024 * 1024,
      tls,
      http2: true,
      http3: true,
      fetch: (req) => app.fetch(req),
    });
  }
}

if (process.env.BARE_WORKER === "1") {
  runWorker();
} else {
  const workers = cpuCount();
  for (let i = 0; i < workers; i++) {
    Bun.spawn(["bun", import.meta.path], {
      env: { ...process.env, BARE_WORKER: "1", BARE_WORKERS: String(workers) },
      stdout: "inherit",
      stderr: "inherit",
    });
  }
}
