// HttpArena entry for swerverts: TypeScript route handlers running in-process on
// the swerver engine via the FFI backend. Dynamic routes (/plaintext, /pipeline,
// /baseline*, /json) are TS handlers reached through libswerver's park/resume
// bridge; static files and the HTTP/2-cleartext listener are served by the
// engine natively. Fork-per-core (workers) fans out via SO_REUSEPORT on Linux.
import { Swerver } from "swerverts";

const datasetPath = process.env["DATASET_PATH"] ?? "/data/dataset.json";
const staticDir = process.env["STATIC_DIR"] ?? "/data/static";
const workers = Number(process.env["WORKERS"] ?? "0"); // 0 = one per CPU

type Item = { id: number; price: number; quantity: number; [k: string]: unknown };
let dataset: Item[] = [];
try {
  dataset = (await Bun.file(datasetPath).json()) as Item[];
} catch {}

function sumParamsAndBody(req: Request, body: string): number {
  let sum = 0;
  const qi = req.url.indexOf("?");
  if (qi >= 0) {
    for (const [, v] of new URLSearchParams(req.url.slice(qi + 1))) {
      const n = parseInt(v, 10);
      if (!Number.isNaN(n)) sum += n;
    }
  }
  const t = body.trim();
  if (t) { const n = parseInt(t, 10); if (!Number.isNaN(n)) sum += n; }
  return sum;
}

// The published @swerver prebuilt engine is built without TLS/HTTP2/HTTP3 (those
// are native-only build flags, so a cross-compiled prebuilt can't carry them),
// so this entry serves plain HTTP/1.1 only. TLS/H2/H3 profiles await natively
// built, feature-enabled prebuilts.
const app = new Swerver({ backend: "ffi", workers, port: 8080 })
  .get("/health", () => new Response(null, { status: 200 }))
  .get("/plaintext", () => "Hello, World!")
  .get("/pipeline", () => "ok")
  .get("/baseline11", (req) => String(sumParamsAndBody(req, "")))
  .post("/baseline11", async (req) => String(sumParamsAndBody(req, await req.text())))
  .get("/baseline2", (req) => String(sumParamsAndBody(req, "")))
  .post("/baseline2", async (req) => String(sumParamsAndBody(req, await req.text())))
  .post("/echo", async (req) => new Response(await req.arrayBuffer(), { headers: { "content-type": "application/octet-stream" } }))
  .get("/json/:count", (req, ctx) => {
    let count = parseInt(ctx.params.count, 10);
    if (!(count > 0)) count = 0;
    if (count > dataset.length) count = dataset.length;
    const qi = req.url.indexOf("?");
    const m = qi >= 0 ? (parseInt(new URLSearchParams(req.url.slice(qi + 1)).get("m") ?? "1", 10) || 1) : 1;
    const items = new Array(count);
    for (let i = 0; i < count; i++) { const d = dataset[i]!; items[i] = { ...d, total: d.price * d.quantity * m }; }
    return ctx.json({ items, count });
  });

const server = await app.start();
console.log(`swerverts httparena up (workers=${workers || "auto"}) ${server.url}`);
const stop = async () => { await server.stop(); process.exit(0); };
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
await new Promise(() => {});
