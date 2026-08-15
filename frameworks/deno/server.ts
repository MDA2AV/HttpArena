// Deno.serve with nothing on top of it. The default export is the shape
// `deno serve` expects; --parallel in the Dockerfile then runs one process per
// core, each binding 8080 with SO_REUSEPORT, so no cluster module is involved
// and there is no worker bookkeeping in here.

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
const JSON_HEADERS = { "content-type": "application/json", "server": "deno" };
const JSON_GZIP_HEADERS = {
  ...JSON_HEADERS,
  "content-encoding": "gzip",
  "vary": "accept-encoding",
};

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

export default {
  async fetch(req: Request): Promise<Response> {
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

    return new Response("Not found", { status: 404, headers: TEXT_HEADERS });
  },
};
