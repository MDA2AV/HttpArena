import { Elysia, status } from "elysia";
import { staticPlugin } from "@elysiajs/static";
import { gzipSync, brotliCompressSync } from "node:zlib";

import { SQL } from "bun";

import cluster from "cluster";
import { availableParallelism } from "os";
import { readFileSync } from "fs";

if (cluster.isPrimary) {
	const workers = availableParallelism();
	for (let i = 0; i < workers; i++) cluster.fork();
} else {
	const datasetItems: any[] = JSON.parse(
		readFileSync("/data/dataset.json", "utf8"),
	);

	// Per-worker pool, capped so workers × perWorker stays under Postgres
	// max_connections. 240 = 256 default minus a reserve for admin/meta.
	const workers = availableParallelism();
	const totalMax = parseInt(process.env.DATABASE_MAX_CONN ?? "", 10) || 256;
	const perWorker = Math.max(1, Math.floor(Math.min(totalMax, 240) / workers));
	const databaseURL = process.env.DATABASE_URL;
	const pg = databaseURL
		? new SQL({ url: databaseURL, max: perWorker })
		: undefined;
	pg?.connect().catch((e) => console.error("pg connect failed:", e));

	// standard mode: Elysia ships no official compression plugin, and the
	// community ones (elysia-compress and its forks) import APIs removed in
	// elysia >= 1.2.6 (vermaysha/elysia-compress#149; the repo is archived).
	// The framework's documented compression mechanism is the mapResponse
	// lifecycle hook — the block below is the official docs example
	// (elysiajs.com/essential/life-cycle) extended with real Accept-Encoding
	// negotiation. Compression runs per request through node:zlib at default
	// settings: no caches, no pre-compressed bodies.
	const encoder = new TextEncoder();
	const THRESHOLD = 1024; // same default as the express/fastify middleware

	// First acceptable encoding in the client's own order, honouring q=0.
	const pickEncoding = (accept: string | undefined) => {
		if (!accept) return null;
		for (const part of accept.split(",")) {
			const [name, ...params] = part.trim().split(";");
			const enc = name.trim().toLowerCase();
			if (enc !== "br" && enc !== "gzip") continue;
			const q = params.find((p) => p.trim().startsWith("q="));
			if (q && parseFloat(q.trim().slice(2)) <= 0) continue;
			return enc;
		}
		return null;
	};

	new Elysia()
		.headers({
			server: "Elysia",
		})
		// The static plugin mounts BEFORE the compression hook on purpose:
		// Elysia hooks only apply to routes registered after them, and letting
		// mapResponse wrap the plugin's not-found flow swallows its 404 into
		// an empty 200. Static files keep the default (uncompressed) path.
		.use(staticPlugin({
			assets: "/data/static",
			prefix: "/static",
		}))
		.mapResponse(({ responseValue, set, headers }) => {
			// Ready-made Responses and files pass through untouched.
			if (responseValue instanceof Response || responseValue instanceof Blob)
				return;

			// Elysia custom-status objects (status() returns, plugin 404s):
			// once a mapResponse hook is registered, falling through here
			// loses the status and yields an empty 200 — map them explicitly.
			const rv = responseValue as any;
			if (typeof rv?.code === "number" && set.status !== 200) {
				const inner = rv.response;
				return new Response(
					typeof inner === "string"
						? inner
						: inner != null
							? JSON.stringify(inner)
							: "",
					{ status: rv.code },
				);
			}

			// headers is absent on the error path — the hook must pass errors
			// through, not throw its own 500.
			const encoding = pickEncoding(headers?.["accept-encoding"]);
			if (!encoding) return;

			const isJson = typeof responseValue === "object";
			const text = isJson
				? JSON.stringify(responseValue)
				: (responseValue?.toString() ?? "");
			if (text.length < THRESHOLD) return;

			set.headers["content-encoding"] = encoding;
			const body = encoder.encode(text);
			return new Response(
				encoding === "br" ? brotliCompressSync(body) : gzipSync(body),
				{
					headers: {
						"content-type": `${
							isJson ? "application/json" : "text/plain"
						}; charset=utf-8`,
					},
				},
			);
		})
		.get("/pipeline", ({ set }) => {
			set.headers["content-type"] = "text/plain";
			return "ok";
		})
		.get("/baseline11", ({ query }) => {
			let sum = 0;
			for (const v of Object.values(query)) sum += +v || 0;
			return sum;
		})
		.post(
			"/baseline11",
			({ query, body }) => {
				let total = 0;
				for (const v of Object.values(query)) total += +v || 0;

				const n = +(body as string);
				if (!isNaN(n)) total += n;

				return total;
			},
			{
				parse: "text",
			},
		)
		.get("/baseline2", ({ query }) => {
			let sum = 0;
			for (const v of Object.values(query)) sum += +v || 0;
			return sum;
		})
		.get("/json/:count", ({ params, query }) => {
			const count = Math.max(
				0,
				Math.min(+params.count || 0, datasetItems.length),
			);
			const m = query.m ? +query.m || 1 : 1;

			const result = {
				count,
				items: datasetItems.slice(0, count).map((d: any) => ({
					id: d.id,
					name: d.name,
					category: d.category,
					price: d.price,
					quantity: d.quantity,
					active: d.active,
					tags: d.tags,
					rating: d.rating,
					total: d.price * d.quantity * m,
				})),
			};

			// json-comp negotiation belongs to the compression plugin mounted
			// above; the handler only serializes.
			return result;
		})
		.get("/async-db", async ({ query }) => {
			if (!pg) return { items: [], count: 0 };

			const min = +query.min || 10;
			const max = +query.max || 50;
			const limit = Math.max(1, Math.min(+query.limit || 50, 50));

			try {
				const rows =
					await pg`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ${min} AND ${max} LIMIT ${limit}`;

				return {
					count: rows.length,
					items: rows.map((r: any) => ({
						id: r.id,
						name: r.name,
						category: r.category,
						price: r.price,
						quantity: r.quantity,
						active: r.active,
						tags: r.tags,
						rating: {
							score: r.rating_score,
							count: r.rating_count,
						},
					})),
				};
			} catch (_) {
				return { items: [], count: 0 };
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
		.onError(({ code }) => {
			if (code === "NOT_FOUND") return status(404);
		})
		.listen(8080);
}
