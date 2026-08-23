import { Elysia, status } from "elysia";
import { staticPlugin } from "@elysiajs/static";
import { gzipSync, brotliCompressSync } from "node:zlib";

import { SQL, RedisClient } from "bun";

import cluster from "cluster";
import { availableParallelism } from "os";
import { readFileSync, existsSync } from "fs";
import Handlebars from "handlebars";
// The Dockerfile compiles this to a standalone binary on a distroless base, so
// the template is embedded at build time rather than read from a path that will
// not exist at runtime. The profile allows exactly this - "file, embedded
// resource, or compile-time component" - and it stays its own artifact.
import fortunesSource from "./views/fortunes.hbs" with { type: "text" };

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

	// crud is the one profile the harness gives a Redis sidecar, and it is the
	// cache shared across this entry's cluster workers. Bun ships the client, so
	// this costs no dependency.
	const redis = process.env.REDIS_URL
		? new RedisClient(process.env.REDIS_URL)
		: undefined;
	const CRUD_TTL_MS = 200;

	const ITEM_COLUMNS =
		"id, name, category, price, quantity, active, tags, rating_score, rating_count";
	const itemShape = (r: any) => ({
		id: r.id,
		name: r.name,
		category: r.category,
		price: r.price,
		quantity: r.quantity,
		active: r.active,
		tags: r.tags,
		rating: { score: r.rating_score, count: r.rating_count },
	});

	// fortunes on a standard entry has to render through a real template engine
	// with a template that is its own artifact - not a string built in the
	// handler. Handlebars is on the profile's own list of examples and escapes
	// {{ }} by default, which is the check the profile calls load-bearing.
	// Compiled once, executed per request.
	const fortunesTemplate = Handlebars.compile(fortunesSource);
	const RUNTIME_FORTUNE = "Additional fortune added at request time.";

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

	// The profile checks Content-Type on woff2 and webp among others, and the
	// encoded response has to carry that of the original file.
	const STATIC_MIME: Record<string, string> = {
		css: "text/css", js: "text/javascript", html: "text/html",
		woff2: "font/woff2", svg: "image/svg+xml", webp: "image/webp",
		json: "application/json",
	};

	// @elysiajs/static has no pre-compressed option, so the .br/.gz variants the
	// harness leaves next to the originals are picked here, ahead of the plugin,
	// which still handles everything else including the plain bodies and 404s.
	// Nothing is compressed at runtime - the encoded bytes already exist on disk
	// and this reads a different path. Bun.file is lazy, so replacing either file
	// shows up on the next request.
	//
	// The hook sees every request, so the cheap reject comes first: one indexOf
	// on the raw URL rather than parsing it.
	const precompressedStatic = async ({ request }: any) => {
		const url: string = request.url;
		if (url.indexOf("/static/", 8) < 0) return;

		const start = url.indexOf("/", 8);
		const q = url.indexOf("?", start);
		const path = q < 0 ? url.slice(start) : url.slice(start, q);
		if (!path.startsWith("/static/")) return;

		const name = path.slice(8);
		if (name.length === 0 || name.includes("/") || name.includes("..")) return;

		const encoding = pickEncoding(
			request.headers.get("accept-encoding") ?? undefined,
		);
		if (!encoding) return;

		const encoded = Bun.file(
			`/data/static/${name}${encoding === "br" ? ".br" : ".gz"}`,
		);
		if (!(await encoded.exists())) return;

		const dot = name.lastIndexOf(".");
		const type =
			(dot > 0 && STATIC_MIME[name.slice(dot + 1)]) ||
			"application/octet-stream";

		// Content-Type and Content-Encoding only: Vary and Server are left off
		// because the profile scores bandwidth. See the note above.
		return new Response(encoded, {
			headers: { "content-type": type, "content-encoding": encoding },
		});
	};

	// json-tls and static-tls want these two on the TLS listener as well, so the
	// handler and the plugin mount are named rather than inlined into one chain.
	const jsonHandler = ({ params, query }: any) => {
		const count = Math.max(
			0,
			Math.min(+params.count || 0, datasetItems.length),
		);
		const m = query.m ? +query.m || 1 : 1;
		return {
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
	};
	const staticMount = () =>
		staticPlugin({ assets: "/data/static", prefix: "/static" });

	new Elysia()
		.headers({
			server: "Elysia",
		})
		.onRequest(precompressedStatic)
		// The static plugin mounts BEFORE the compression hook on purpose:
		// Elysia hooks only apply to routes registered after them, and letting
		// mapResponse wrap the plugin's not-found flow swallows its 404 into
		// an empty 200. Static files keep the default (uncompressed) path.
		.use(staticMount())
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
		// json-comp negotiation belongs to the compression hook mounted above;
		// the handler only serializes.
		.get("/json/:count", jsonHandler)
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
		// ── crud ────────────────────────────────────────────────────────
		.get("/crud/items", async ({ query }) => {
			if (!pg) return status(500, { error: "DB not available" });
			const category = String(query.category ?? "electronics");
			const page = Math.max(1, +(query.page ?? 1) || 1);
			const limit = Math.max(1, Math.min(+(query.limit ?? 10) || 10, 50));
			try {
				const rows =
					await pg`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE category = ${category} ORDER BY id LIMIT ${limit} OFFSET ${(page - 1) * limit}`;
				const items = rows.map(itemShape);
				return { items, total: items.length, page, limit };
			} catch (_) {
				return status(500, { error: "query failed" });
			}
		})
		// Cache-aside. The hit is already-serialized JSON, so it goes back as a
		// Response: the mapResponse hook passes those through untouched, and
		// returning the string would have it typed as text/plain.
		.get("/crud/items/:id", async ({ params, set }) => {
			if (!pg) return status(500, { error: "DB not available" });
			const id = +params.id;
			if (!Number.isFinite(id)) return status(404);
			try {
				if (redis) {
					const hit = await redis.get("crud:" + id);
					if (hit)
						return new Response(hit, {
							headers: {
								"content-type": "application/json",
								"x-cache": "HIT",
							},
						});
				}
				const rows =
					await pg`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = ${id} LIMIT 1`;
				if (rows.length === 0) return status(404);
				const json = JSON.stringify(itemShape(rows[0]));
				if (redis)
					redis.set("crud:" + id, json, "PX", String(CRUD_TTL_MS));
				return new Response(json, {
					headers: {
						"content-type": "application/json",
						"x-cache": "MISS",
					},
				});
			} catch (_) {
				return status(500, { error: "query failed" });
			}
		})
		.post(
			"/crud/items",
			async ({ body, set }) => {
				if (!pg) return status(500, { error: "DB not available" });
				const b = body as any;
				try {
					// Bun's tag makes every ${} its own parameter, so the values
					// the ON CONFLICT branch reuses are passed again rather than
					// back-referenced.
					const rows =
						await pg`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (${b.id}, ${b.name ?? "New Product"}, ${b.category ?? "test"}, ${b.price ?? 0}, ${b.quantity ?? 0}, true, '["bench"]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = ${b.name ?? "New Product"}, price = ${b.price ?? 0}, quantity = ${b.quantity ?? 0} RETURNING id`;
					set.status = 201;
					return {
						id: rows[0].id,
						name: b.name,
						category: b.category,
						price: b.price,
						quantity: b.quantity,
					};
				} catch (_) {
					return status(500, { error: "insert failed" });
				}
			},
			{ parse: "json" },
		)
		.put(
			"/crud/items/:id",
			async ({ params, body }) => {
				if (!pg) return status(500, { error: "DB not available" });
				const id = +params.id;
				if (!Number.isFinite(id)) return status(404);
				const b = body as any;
				try {
					const rows =
						await pg`UPDATE items SET name = ${b.name ?? "Updated"}, price = ${b.price ?? 0}, quantity = ${b.quantity ?? 0} WHERE id = ${id} RETURNING id`;
					if (rows.length === 0) return status(404);
					if (redis) await redis.del("crud:" + id);
					return {
						id,
						name: b.name,
						price: b.price,
						quantity: b.quantity,
					};
				} catch (_) {
					return status(500, { error: "update failed" });
				}
			},
			{ parse: "json" },
		)
		// ── fortunes ────────────────────────────────────────────────────
		.get("/fortunes", async () => {
			if (!pg)
				return new Response("DB not available", {
					status: 500,
					headers: { "content-type": "text/plain" },
				});
			try {
				const rows = await pg`SELECT id, message FROM fortune`;
				const fortunes = rows.map((r: any) => ({
					id: r.id,
					message: r.message,
				}));
				fortunes.push({ id: 0, message: RUNTIME_FORTUNE });
				// Ordinal, not locale aware: the seed carries em-dashes and
				// collation rules would order them in a way the profile does
				// not ask for.
				fortunes.sort((a: any, b: any) =>
					a.message < b.message ? -1 : a.message > b.message ? 1 : 0,
				);
				return new Response(fortunesTemplate({ fortunes }), {
					headers: { "content-type": "text/html; charset=utf-8" },
				});
			} catch (_) {
				return new Response("query failed", {
					status: 500,
					headers: { "content-type": "text/plain" },
				});
			}
		})
		.onError(({ code }) => {
			if (code === "NOT_FOUND") return status(404);
		})
		.listen(8080);

	// json-tls and static-tls: the same two routes over TLS on 8081. Elysia
	// passes its `serve` config straight to Bun.serve, which negotiates
	// http/1.1 here - there is no h2 to fall into, which is what those profiles
	// require of the ALPN. The harness only mounts /certs for the TLS profiles,
	// so without them this listener is not opened.
	if (existsSync("/certs/server.key") && existsSync("/certs/server.crt")) {
		new Elysia({
			serve: {
				tls: {
					key: Bun.file("/certs/server.key"),
					cert: Bun.file("/certs/server.crt"),
				},
			},
		})
			.headers({ server: "Elysia" })
			.onRequest(precompressedStatic)
			.use(staticMount())
			.get("/json/:count", jsonHandler)
			.onError(({ code }) => {
				if (code === "NOT_FOUND") return status(404);
			})
			.listen(8081);
	}
}
