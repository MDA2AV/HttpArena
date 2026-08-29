//! production-stack handlers — the `/api/*` cache-aside paths behind the edge.
//!
//! The framework never sees a JWT here. The edge verifies every `/api/*` request against the
//! shared authsvc sidecar and forwards the `X-User-Id` it hands back, so everything in this
//! module treats that header as already trusted.
//!
//! Reads are cache-aside over two tiers: moka in-process (L1) and Redis (L2). `X-Cache` reports
//! `HIT` when either tier answered and `MISS` when the request reached Postgres, which is what
//! the profile's cache-aside assertion checks. Writes clear both tiers so the next read is a
//! genuine `MISS` rather than a stale entry waiting out its TTL.

use crate::{
    handlers::APPLICATION_JSON,
    state::{AppState, ITEM_TTL, Rating, USER_TTL},
};
use deadpool_postgres::Pool;
use deadpool_redis::{Pool as RedisPool, redis::cmd};
use serde::{Deserialize, Serialize};
use std::{sync::Arc, time::Duration};
use trillium::{Conn, KnownHeaderName, Status};
use trillium_router::RouterConnExt;

#[derive(Debug, Serialize)]
struct ApiItem {
    id: i32,
    name: String,
    category: String,
    price: i32,
    quantity: i32,
    active: bool,
    tags: serde_json::Value,
    rating: Rating,
}

#[derive(Debug, Serialize)]
struct ApiUser {
    id: i32,
    name: String,
    email: String,
    plan: String,
}

fn cached_json(conn: Conn, body: Arc<[u8]>, cache: &'static str) -> Conn {
    conn.with_status(Status::Ok)
        .with_response_header(KnownHeaderName::ContentType, APPLICATION_JSON)
        .with_response_header("x-cache", cache)
        .with_body(body)
        .halt()
}

// ── L2 (Redis) ─────────────────────────────────────────────────────────────
//
// Every one of these swallows its error into `None`/`()`. A cache tier that is down should
// degrade the stack to Postgres, not fail the request — and on a miss path the write-back is
// advisory anyway.

async fn l2_get(pool: &RedisPool, key: &str) -> Option<Arc<[u8]>> {
    let mut conn = pool.get().await.ok()?;
    let bytes: Option<Vec<u8>> = cmd("GET").arg(key).query_async(&mut conn).await.ok()?;
    bytes.map(Into::into)
}

async fn l2_set(pool: &RedisPool, key: &str, body: &[u8], ttl: Duration) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };
    // PX rather than EX: the item TTL is a second and the user TTL is thirty, and expressing
    // both in milliseconds keeps one code path.
    let ttl_ms = u64::try_from(ttl.as_millis()).unwrap_or(u64::MAX);
    let _: Result<(), _> = cmd("SET")
        .arg(key)
        .arg(body)
        .arg("PX")
        .arg(ttl_ms)
        .query_async::<()>(&mut conn)
        .await;
}

async fn l2_del(pool: &RedisPool, key: &str) {
    let Ok(mut conn) = pool.get().await else {
        return;
    };
    let _: Result<(), _> = cmd("DEL").arg(key).query_async::<()>(&mut conn).await;
}

// ── GET /api/items/:id ─────────────────────────────────────────────────────

pub async fn api_item_read(conn: Conn) -> Conn {
    let Some(id) = conn.param("id").and_then(|s| s.parse::<i32>().ok()) else {
        return conn.with_status(Status::BadRequest).halt();
    };
    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));

    if let Some(body) = state.items_l1.get(&id).await {
        return cached_json(conn, body, "HIT");
    }

    let key = format!("item:{id}");

    if let Some(redis) = &state.redis {
        if let Some(body) = l2_get(redis, &key).await {
            // Promote to L1 so the next read on this id never leaves the process.
            state.items_l1.insert(id, Arc::clone(&body)).await;
            return cached_json(conn, body, "HIT");
        }
    }

    let Some(pool) = &state.pg else {
        return conn.with_status(Status::ServiceUnavailable).halt();
    };

    let item = match query_item(pool, id).await {
        Ok(Some(item)) => item,
        Ok(None) => return conn.with_status(Status::NotFound).halt(),
        Err(e) => {
            log::warn!("api item read failed: {e}");
            return conn.with_status(Status::InternalServerError).halt();
        }
    };

    let body: Arc<[u8]> = sonic_rs::to_vec(&item).unwrap_or_default().into();
    state.items_l1.insert(id, Arc::clone(&body)).await;
    if let Some(redis) = &state.redis {
        l2_set(redis, &key, &body, ITEM_TTL).await;
    }

    cached_json(conn, body, "MISS")
}

async fn query_item(
    pool: &Pool,
    id: i32,
) -> Result<Option<ApiItem>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
             FROM items WHERE id = $1",
        )
        .await?;
    Ok(client.query_opt(&stmt, &[&id]).await?.map(|row| ApiItem {
        id: row.get(0),
        name: row.get(1),
        category: row.get(2),
        price: row.get(3),
        quantity: row.get(4),
        active: row.get(5),
        tags: row.get::<_, serde_json::Value>(6),
        rating: Rating {
            score: row.get::<_, i32>(7) as u32,
            count: row.get::<_, i32>(8) as u32,
        },
    }))
}

// ── POST /api/items/:id ────────────────────────────────────────────────────

#[derive(Deserialize)]
struct ApiItemWrite {
    name: Option<String>,
    price: Option<i32>,
    quantity: Option<i32>,
}

pub async fn api_item_write(mut conn: Conn) -> Conn {
    let Some(id) = conn.param("id").and_then(|s| s.parse::<i32>().ok()) else {
        return conn.with_status(Status::BadRequest).halt();
    };
    let Ok(body) = conn.request_body_string().await else {
        return conn.with_status(Status::BadRequest).halt();
    };
    let Ok(input) = sonic_rs::from_str::<ApiItemWrite>(&body) else {
        return conn.with_status(Status::UnprocessableEntity).halt();
    };

    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));
    let Some(pool) = &state.pg else {
        return conn.with_status(Status::ServiceUnavailable).halt();
    };

    if let Err(e) = update_item(pool, id, &input).await {
        log::warn!("api item write failed: {e}");
        return conn.with_status(Status::InternalServerError).halt();
    }

    // Both tiers, in that order. Dropping L1 first means a concurrent read cannot re-promote
    // the stale L2 value into L1 after we have cleared it.
    state.items_l1.invalidate(&id).await;
    if let Some(redis) = &state.redis {
        l2_del(redis, &format!("item:{id}")).await;
    }

    conn.with_status(Status::NoContent).halt()
}

async fn update_item(
    pool: &Pool,
    id: i32,
    input: &ApiItemWrite,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached(
            "UPDATE items SET name = COALESCE($2, name), price = COALESCE($3, price), quantity = \
             COALESCE($4, quantity) WHERE id = $1",
        )
        .await?;
    client
        .execute(&stmt, &[&id, &input.name, &input.price, &input.quantity])
        .await?;
    Ok(())
}

// ── GET /api/me ────────────────────────────────────────────────────────────

pub async fn api_me(conn: Conn) -> Conn {
    // Set by the edge from the `sub` claim authsvc verified. Anything reaching this handler
    // without it did not come through the edge.
    let Some(id) = conn
        .request_headers()
        .get_str("x-user-id")
        .and_then(|s| s.parse::<i32>().ok())
    else {
        return conn.with_status(Status::Unauthorized).halt();
    };
    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));

    if let Some(body) = state.users_l1.get(&id).await {
        return cached_json(conn, body, "HIT");
    }

    let key = format!("user:{id}");

    if let Some(redis) = &state.redis {
        if let Some(body) = l2_get(redis, &key).await {
            state.users_l1.insert(id, Arc::clone(&body)).await;
            return cached_json(conn, body, "HIT");
        }
    }

    let Some(pool) = &state.pg else {
        return conn.with_status(Status::ServiceUnavailable).halt();
    };

    let user = match query_user(pool, id).await {
        Ok(Some(user)) => user,
        Ok(None) => return conn.with_status(Status::NotFound).halt(),
        Err(e) => {
            log::warn!("api me failed: {e}");
            return conn.with_status(Status::InternalServerError).halt();
        }
    };

    let body: Arc<[u8]> = sonic_rs::to_vec(&user).unwrap_or_default().into();
    state.users_l1.insert(id, Arc::clone(&body)).await;
    if let Some(redis) = &state.redis {
        l2_set(redis, &key, &body, USER_TTL).await;
    }

    cached_json(conn, body, "MISS")
}

async fn query_user(
    pool: &Pool,
    id: i32,
) -> Result<Option<ApiUser>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached("SELECT id, name, email, plan FROM users WHERE id = $1")
        .await?;
    Ok(client.query_opt(&stmt, &[&id]).await?.map(|row| ApiUser {
        id: row.get(0),
        name: row.get(1),
        email: row.get(2),
        plan: row.get(3),
    }))
}
