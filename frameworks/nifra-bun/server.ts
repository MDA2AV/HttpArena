import { existsSync, readFileSync } from "node:fs"
import os from "node:os"
import Handlebars from "handlebars"
import pg from "pg"
import { compression } from "@nifrajs/middleware"
import { server } from "@nifrajs/core/server"
import { serveStatic } from "@nifrajs/core/serve-static"

type Item = {
  id: number
  name: string
  category: string
  price: number
  quantity: number
  active: boolean
  tags: string[]
  rating: { score: number; count: number }
}

type DatabaseItem = Omit<Item, "rating"> & {
  tags: string[] | unknown
  rating_score: number
  rating_count: number
}

type Fortune = { id: number; message: string }

function cpuCount(): number {
  try {
    const [quota, period] = readFileSync("/sys/fs/cgroup/cpu.max", "utf8").trim().split(" ")
    if (quota !== "max") {
      const limited = Math.floor(Number(quota) / Number(period))
      if (limited >= 1) return limited
    }
  } catch {
    // A non-cgroup host uses Node's own parallelism estimate below.
  }
  return os.availableParallelism ? os.availableParallelism() : os.cpus().length
}

function loadDataset(): Item[] {
  try {
    const value: unknown = JSON.parse(readFileSync("/data/dataset.json", "utf8"))
    return Array.isArray(value) ? (value as Item[]) : []
  } catch {
    // The dataset is mounted by HttpArena; the other profiles can still run without it.
    return []
  }
}

function integer(value: string | null | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10)
  return Number.isFinite(parsed) ? parsed : fallback
}

function sumQuery(query: URLSearchParams): number {
  let sum = 0
  for (const value of query.values()) {
    const parsed = Number.parseInt(value, 10)
    if (Number.isFinite(parsed)) sum += parsed
  }
  return sum
}

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
  }
}

function buildApp() {
  const dataset = loadDataset()
  const workerCount = cpuCount()
  const databaseUrl = process.env.DATABASE_URL
  const connectionLimit = Math.max(
    1,
    Math.floor((integer(process.env.DATABASE_MAX_CONN, 256) || 256) / workerCount),
  )
  const pool = databaseUrl
    ? new pg.Pool({ connectionString: databaseUrl, max: connectionLimit })
    : undefined
  pool?.on("error", () => {})
  const staticFiles = serveStatic({
    dir: "/data/static",
    prefix: "/static",
    immutable: false,
  })
  const fortunesSource = readFileSync("/app/views/fortunes.hbs", "utf8")
  const renderFortunes = Handlebars.compile(fortunesSource)

  const app = server()
    .get("/pipeline", (c) => c.text("ok"))
    .get("/delay/:ms", async (c) => {
      const ms = Math.max(0, integer(c.params.ms, 0))
      if (ms > 0) await new Promise<void>((resolve) => setTimeout(resolve, ms))
      return c.text(String(ms))
    })
    .get("/baseline11", (c) => c.text(String(sumQuery(c.query))))
    .post("/baseline11", async (c) => {
      const body = Number.parseInt((await c.req.text()).trim(), 10)
      const total = sumQuery(c.query) + (Number.isFinite(body) ? body : 0)
      return c.text(String(total))
    })
    .get("/baseline2", (c) => c.text(String(sumQuery(c.query))))
    // Compression runs for /json only, the one route the profiles ask to be compressed.
    .group("/json", (g) =>
      g.use(compression()).get("/:count", (c) => {
        const count = Math.min(Math.max(0, integer(c.params.count, 0)), dataset.length)
        const multiplier = integer(c.query.get("m"), 1) || 1
        const items = new Array<Item & { total: number }>(count)
        for (let i = 0; i < count; i++) {
          const item = dataset[i]!
          items[i] = {
            ...item,
            total: item.price * item.quantity * multiplier,
          }
        }
        return c.json({ items, count })
      }),
    )
    .post("/echo", async (c) =>
      new Response(await c.req.arrayBuffer(), {
        headers: { "content-type": "application/octet-stream" },
      }),
    )
    .get("/async-db", async (c) => {
      if (pool === undefined) return c.json({ items: [], count: 0 })
      const min = integer(c.query.get("min"), 10)
      const max = integer(c.query.get("max"), 50)
      const limit = Math.min(50, Math.max(1, integer(c.query.get("limit"), 50)))
      try {
        const result = await pool.query<DatabaseItem>(
          "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
          [min, max, limit],
        )
        const items = result.rows.map(itemFromDatabase)
        return c.json({ items, count: items.length })
      } catch {
        return c.json({ items: [], count: 0 })
      }
    })
    .get("/fortunes", async (c) => {
      if (pool === undefined) return c.text("DB not available", 500)
      try {
        const result = await pool.query<Fortune>("SELECT id, message FROM fortune")
        const fortunes = [...result.rows, { id: 0, message: "Additional fortune added at request time." }]
        fortunes.sort((a, b) => (a.message < b.message ? -1 : a.message > b.message ? 1 : 0))
        return c.text(renderFortunes({ fortunes }), {
          headers: { "content-type": "text/html; charset=utf-8" },
        })
      } catch {
        return c.text("query failed", 500)
      }
    })

  return { app, staticFiles }
}

function runWorker(): void {
  const { app, staticFiles } = buildApp()
  // reusePort lets every process bind the same port; the kernel spreads connections across them.
  app.listen(8080, { reusePort: true, static: staticFiles })
  if (existsSync("/certs/server.crt") && existsSync("/certs/server.key")) {
    app.listen(8081, {
      reusePort: true,
      static: staticFiles,
      tls: {
        cert: readFileSync("/certs/server.crt"),
        key: readFileSync("/certs/server.key"),
      },
    })
  }
}

if (process.env.NIFRA_WORKER === "1") {
  runWorker()
} else {
  for (let i = 0; i < cpuCount(); i++) {
    Bun.spawn(["bun", import.meta.path], {
      env: { ...process.env, NIFRA_WORKER: "1" },
      stdout: "inherit",
      stderr: "inherit",
    })
  }
}
