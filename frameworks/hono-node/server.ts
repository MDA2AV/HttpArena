import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { compress } from "hono/compress";
import cluster from "node:cluster";
import os from "node:os";
import { existsSync, readFileSync } from "node:fs";
import { createServer as createHttpsServer } from "node:https";

const SERVER_NAME = "hono-node";

// The container is pinned to a cpuset, so os.availableParallelism() alone would
// fork one worker per host core. Read the cgroup quota first, like the other
// node entries do.
function getCPUCount(): number {
  try {
    const max = readFileSync("/sys/fs/cgroup/cpu.max", "utf8").trim();
    const [quota, period] = max.split(" ");
    if (quota !== "max") {
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
  // A missing dataset serves an empty list instead of taking the worker down
  let datasetItems: any[] = [];
  try {
    datasetItems = JSON.parse(readFileSync(process.env.DATASET_PATH || "/data/dataset.json", "utf8"));
  } catch (e) {}

  const app = new Hono();

  // json-comp: Hono's own middleware, which on Node compresses through
  // CompressionStream. Scoped to /json so the other endpoints don't pay the
  // encoder cost.
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

  // Catch-all
  app.all("*", () => new Response("Not found", { status: 404 }));

  // Start — node:http through the Hono adapter, one worker per core
  serve({ fetch: app.fetch, port: 8080 });

  // json-tls on 8081: the same app.fetch behind node:https. The adapter takes the
  // server factory, so this is the identical Hono instance and middleware chain,
  // not a second copy of the routes. Certs are only mounted for the TLS profiles.
  if (existsSync("/certs/server.crt") && existsSync("/certs/server.key")) {
    serve({
      fetch: app.fetch,
      port: 8081,
      createServer: createHttpsServer,
      serverOptions: {
        key: readFileSync("/certs/server.key"),
        cert: readFileSync("/certs/server.crt"),
      },
    });
  }
}
