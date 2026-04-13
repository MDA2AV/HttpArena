import { Elysia } from "elysia";
import { SQL } from "bun";
import { readFileSync } from "fs";
import cluster from "cluster";
import { availableParallelism } from "os";

// Worker count: env override wins, else one per CPU. Each worker costs
// ~150 MB RSS. Override with ELYSIA_WORKERS env var to cap lower on small boxes.
const WORKERS = Math.max(
	1,
	Math.min(
		parseInt(process.env.ELYSIA_WORKERS ?? "", 10) || availableParallelism(),
		availableParallelism(),
	),
);

if (cluster.isPrimary) {
	for (let i = 0; i < WORKERS; i++) cluster.fork();
	cluster.on("exit", (w) => {
		console.error(`worker ${w.process.pid} exited, respawning`);
		cluster.fork();
	});
} else {

const MIME_TYPES: Record<string, string> = {
	".css": "text/css",
	".js": "application/javascript",
	".html": "text/html",
	".woff2": "font/woff2",
	".svg": "image/svg+xml",
	".webp": "image/webp",
	".json": "application/json",
};

// Preload dataset for /json
const datasetItems: any[] = JSON.parse(
	readFileSync("/data/dataset.json", "utf8"),
);

const STATIC_DIR = "/data/static";

// Postgres client for /async-db (Bun native SQL)
const databaseURL = process.env.DATABASE_URL;
// Bun.SQL auto-connects on first query — don't call .connect() explicitly,
// it isn't reliably exposed on the base client and throws in some versions.
const pg: SQL | undefined = databaseURL ? new SQL(databaseURL) : undefined;

const EMPTY_DB_JSON = '{"items":[],"count":0}';

new Elysia()
	.get("/pipeline", () => new Response("ok", { headers: { "content-type": "text/plain" } }))
	.get("/baseline11", ({ query }) => {
		let sum = 0;
		for (const v of Object.values(query)) sum += parseInt(v as string, 10) || 0;
		return new Response(String(sum), {
			headers: { "content-type": "text/plain" },
		});
	})
	.post("/baseline11", async ({ query, request }) => {
		let total = 0;
		for (const v of Object.values(query)) total += parseInt(v as string, 10) || 0;
		const body = await request.text();
		const n = parseInt(body.trim(), 10);
		if (!isNaN(n)) total += n;
		return new Response(String(total), {
			headers: { "content-type": "text/plain" },
		});
	})
	.get("/baseline2", ({ query }) => {
		let sum = 0;
		for (const v of Object.values(query)) sum += parseInt(v as string, 10) || 0;
		return new Response(String(sum), {
			headers: { "content-type": "text/plain" },
		});
	})
	.get("/json/:count", ({ params, query, request }) => {
		const count = Math.max(
			0,
			Math.min(parseInt(params.count, 10) || 0, datasetItems.length),
		);
		const m = parseInt((query.m as string) ?? "", 10) || 1;

		const items = datasetItems.slice(0, count).map((d: any) => ({
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
		const body = JSON.stringify({ count, items });

		const ae = request.headers.get("accept-encoding") || "";
		if (ae.includes("gzip")) {
			const compressed = Bun.gzipSync(body);
			return new Response(compressed, {
				headers: {
					"content-type": "application/json",
					"content-encoding": "gzip",
					"content-length": String(compressed.length),
				},
			});
		}

		return new Response(body, {
			headers: {
				"content-type": "application/json",
				"content-length": String(Buffer.byteLength(body)),
			},
		});
	})
	.get("/async-db", async ({ query }) => {
		if (!pg) {
			return new Response(EMPTY_DB_JSON, {
				headers: { "content-type": "application/json" },
			});
		}
		const min = parseInt((query.min as string) ?? "", 10) || 10;
		const max = parseInt((query.max as string) ?? "", 10) || 50;
		const limit = Math.max(1, Math.min(parseInt((query.limit as string) ?? "", 10) || 50, 50));
		try {
			const rows = (await pg`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ${min} AND ${max} LIMIT ${limit}`) as any[];
			const items = rows.map((r: any) => ({
				id: r.id,
				name: r.name,
				category: r.category,
				price: r.price,
				quantity: r.quantity,
				active: r.active,
				tags: r.tags,
				rating: { score: r.rating_score, count: r.rating_count },
			}));
			const body = JSON.stringify({ count: items.length, items });
			return new Response(body, {
				headers: {
					"content-type": "application/json",
					"content-length": String(Buffer.byteLength(body)),
				},
			});
		} catch (e) {
			return new Response(EMPTY_DB_JSON, {
				headers: { "content-type": "application/json" },
			});
		}
	})
	.post("/upload", async ({ request }) => {
		let size = 0;
		if (request.body) {
			for await (const chunk of request.body as any) {
				size += (chunk as Uint8Array).byteLength;
			}
		}
		return new Response(String(size), {
			headers: { "content-type": "text/plain" },
		});
	})
	.get("/static/:filename", async ({ params }) => {
		const name = params.filename;
		const file = Bun.file(`${STATIC_DIR}/${name}`);
		if (!(await file.exists())) {
			return new Response("Not found", { status: 404 });
		}
		const ext = name.slice(name.lastIndexOf("."));
		const ct = MIME_TYPES[ext] || "application/octet-stream";
		return new Response(file, {
			headers: { "content-type": ct },
		});
	})
	.all("*", () => new Response("Not found", { status: 404 }))
	.listen({ port: 8080, reusePort: true });
}
