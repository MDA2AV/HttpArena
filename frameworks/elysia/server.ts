import { Elysia, status } from "elysia";
import { staticPlugin } from "@elysiajs/static";

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

	new Elysia()
		.headers({
			server: "Elysia",
		})
		.use(staticPlugin({
			assets: "/data/static",
			prefix: "/static",
		}))
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
		.get("/json/:count", ({ params, query, headers, set }) => {
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

			const encoding = headers["accept-encoding"];
			if (encoding) {
				const index = encoding.indexOf(",");
				const type =
					index === -1 ? encoding : encoding.slice(0, index);

				set.headers["content-type"] = "application/json";
				if (type === "gzip") {
					set.headers["content-encoding"] = "gzip";
					return Bun.gzipSync(JSON.stringify(result));
				} else if (encoding === "br") {
					set.headers["content-encoding"] = "br";
					return Bun.deflateSync(JSON.stringify(result));
				} else if (encoding === "deflate") {
					set.headers["content-encoding"] = "deflate";
					return Bun.deflateSync(JSON.stringify(result));
				}
			}

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
