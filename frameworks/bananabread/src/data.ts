/**
 * Data layer: the `/json` dataset (from DATASET_PATH) and PostgreSQL access via Bun's built-in
 * SQL client (Bun.SQL). When DATABASE_URL is unset, the DB queries return empty so the
 * database-backed endpoints degrade gracefully.
 */
import { SQL } from "bun";
import type { CrudCreateRequest, CrudUpdateRequest, DatasetItem, DbItem } from "./model.ts";

const datasetFile = Bun.file(process.env.DATASET_PATH ?? "/data/dataset.json");
export const dataset: DatasetItem[] = (await datasetFile.exists()) ? ((await datasetFile.json()) as DatasetItem[]) : [];

// One Bun.SQL pool lives per worker process (Seagreen forks one worker per core), and the pools
// must collectively stay under PostgreSQL's max_connections (the harness caps it at 256). The
// default per-pool size (~10) × ~64 workers ≈ 640 connections blows past that, and the overflow
// fails to open under load — surfacing as 5xx (and reconnect storms that wreck throughput). Size
// each worker's pool so workers × poolMax stays well under 256 (~200, leaving headroom for
// reserved/health connections); this matches the worker count main.ts derives.
const workerCount = Number(process.env.WORKERS) || navigator.hardwareConcurrency || 1;
const poolMax = Math.max(1, Math.floor(200 / workerCount));
const sql = process.env.DATABASE_URL ? new SQL(process.env.DATABASE_URL, { max: poolMax }) : null;
export const dbAvailable = sql !== null;

// biome-ignore lint/suspicious/noExplicitAny: Bun.SQL rows are untyped records
function toDbItem(r: any): DbItem {
  return {
    id: r.id,
    name: r.name,
    category: r.category,
    price: r.price,
    quantity: r.quantity,
    active: r.active,
    tags: r.tags ?? [],
    rating: { score: r.rating_score, count: r.rating_count },
  };
}

export async function rangeByPrice(min: number, max: number, limit: number): Promise<DbItem[]> {
  if (!sql) return [];
  const rows = await sql`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
                         FROM items WHERE price BETWEEN ${min} AND ${max} LIMIT ${limit}`;
  return rows.map(toDbItem);
}

export async function listByCategory(category: string, limit: number, offset: number): Promise<DbItem[]> {
  if (!sql) return [];
  const rows = await sql`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
                         FROM items WHERE category = ${category} ORDER BY id LIMIT ${limit} OFFSET ${offset}`;
  return rows.map(toDbItem);
}

export async function findById(id: number): Promise<DbItem | null> {
  if (!sql) return null;
  const rows = await sql`SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
                         FROM items WHERE id = ${id} LIMIT 1`;
  return rows.length ? toDbItem(rows[0]) : null;
}

export async function upsert(req: CrudCreateRequest): Promise<void> {
  if (!sql) return;
  const tags = JSON.stringify(req.tags ?? ["bench"]);
  await sql`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
            VALUES (${req.id}, ${req.name}, ${req.category}, ${req.price}, ${req.quantity}, ${req.active ?? true}, ${tags}::jsonb, 0, 0)
            ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category,
              price = EXCLUDED.price, quantity = EXCLUDED.quantity, active = EXCLUDED.active, tags = EXCLUDED.tags`;
}

export async function update(id: number, req: CrudUpdateRequest): Promise<boolean> {
  if (!sql) return false;
  const rows = await sql`UPDATE items SET
              name = COALESCE(${req.name ?? null}, name),
              price = COALESCE(${req.price ?? null}, price),
              quantity = COALESCE(${req.quantity ?? null}, quantity)
            WHERE id = ${id} RETURNING id`;
  return rows.length > 0;
}
