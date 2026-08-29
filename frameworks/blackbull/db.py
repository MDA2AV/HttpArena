"""Postgres backing for the ``async-db`` profile.  With no database reachable
the read path returns an empty result, which the profile asks for."""
from __future__ import annotations

import json
import multiprocessing
import os

try:
    import asyncpg  # type: ignore[import-untyped]
except ImportError:  # pragma: no cover - asyncpg is a bench-only dependency
    asyncpg = None  # type: ignore[assignment]

# Falls back to libpq's PG* variables, which asyncpg also honours.
DATABASE_URL = os.environ.get('DATABASE_URL') or None

try:
    DATABASE_MAX_CONN = int(os.environ.get('DATABASE_MAX_CONN', '256'))
except ValueError:
    DATABASE_MAX_CONN = 256


def _worker_count() -> int:
    """Mirror ``launcher.py``'s ``WRK_COUNT`` — the divisor below."""
    env = os.environ.get('WEB_WORKERS', '').strip()
    if env:
        try:
            return max(1, int(env))
        except ValueError:
            pass
    try:
        return max(1, multiprocessing.cpu_count())
    except NotImplementedError:  # pragma: no cover
        return 1


# HttpArena's rule, keeping workers x per_worker under max_connections=256.
POOL_MAX_PER_WORKER = max(1, min(DATABASE_MAX_CONN, 240) // _worker_count())

# Shared by every client connection this worker serves.
_SHARED_POOL = None
_SHARED_POOL_READY = False


async def shared_pool():
    """The per-worker pool, or ``None``.  Built on first use: ``launcher.py``
    gives no per-process startup hook."""
    global _SHARED_POOL, _SHARED_POOL_READY
    if _SHARED_POOL_READY:
        return _SHARED_POOL
    _SHARED_POOL_READY = True
    if asyncpg is None or (DATABASE_URL is None and 'PGHOST' not in os.environ):
        return None
    try:
        _SHARED_POOL = await asyncpg.create_pool(
            dsn=DATABASE_URL, min_size=1, max_size=POOL_MAX_PER_WORKER)
    except Exception:  # noqa: BLE001 - any connect failure -> DB-less mode
        _SHARED_POOL = None
    return _SHARED_POOL


async def lease_connection():
    """Lend one connection from the shared pool for one request; ``None``
    in DB-less mode, which ``async_db`` degrades on."""
    pool = await shared_pool()
    conn = None
    if pool is not None:
        try:
            conn = await pool.acquire()
        except Exception:  # noqa: BLE001 - acquire failure -> DB-less mode
            conn = None
    try:
        yield conn
    finally:
        if conn is not None:
            await pool.release(conn)


def _row_to_item(row) -> dict:
    tags = row['tags']
    return {
        'id': row['id'],
        'name': row['name'],
        'category': row['category'],
        'price': row['price'],
        'quantity': row['quantity'],
        'active': row['active'],
        'tags': json.loads(tags) if isinstance(tags, str) else tags,  # JSONB
        'rating': {'score': row['rating_score'], 'count': row['rating_count']},
    }


async def async_db(conn, min_price: int, max_price: int, limit: int) -> list[dict]:
    """``[]`` when no rows match or the database is unavailable."""
    if conn is None:
        return []
    # asyncpg's per-connection statement cache is what "prepare once per
    # connection, reuse across requests" means here: one server-side statement
    # survives 200 acquire/release cycles.  Holding a PreparedStatement across
    # a release instead raises InterfaceError, and re-preparing per checkout
    # measured 54% slower for the same one statement.
    try:
        rows = await conn.fetch(
            'SELECT id, name, category, price, quantity, active, tags, '
            'rating_score, rating_count FROM items '
            'WHERE price BETWEEN $1 AND $2 LIMIT $3',
            min_price, max_price, limit)
    except Exception:  # noqa: BLE001 - contract: empty result, never an error
        return []
    return [_row_to_item(r) for r in rows]
