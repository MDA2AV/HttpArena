use crate::{
    handlers::{APPLICATION_JSON, json_response},
    state::{AppState, CRUD_CACHE_TTL, CacheEntry, Rating},
};
use deadpool_postgres::Pool;
use querystrong::QueryStrong;
use serde::{Deserialize, Serialize};
use std::{sync::Arc, time::Instant};
use trillium::{Conn, KnownHeaderName, Status};
use trillium_router::RouterConnExt;

#[derive(Debug, Serialize)]
struct CrudItem {
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
struct CrudListResponse {
    items: Vec<CrudItem>,
    total: usize,
    page: i64,
    limit: i64,
}

pub async fn crud_list(conn: Conn) -> Conn {
    let qs = QueryStrong::parse(conn.querystring());
    let category = qs.get_str("category").unwrap_or("electronics").to_string();
    let page: i64 = qs
        .get_str("page")
        .and_then(|s| s.parse().ok())
        .unwrap_or(1)
        .max(1);
    let limit: i64 = qs
        .get_str("limit")
        .and_then(|s| s.parse().ok())
        .unwrap_or(10)
        .clamp(1, 50);
    let offset = (page - 1) * limit;

    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));
    let Some(pool) = &state.pg else {
        return json_response(
            conn,
            br#"{"items":[],"total":0,"page":1,"limit":10}"#.to_vec(),
        );
    };

    let items = match query_crud_list(pool, &category, limit, offset).await {
        Ok(items) => items,
        Err(e) => {
            log::warn!("crud list failed: {e}");
            vec![]
        }
    };

    let total = items.len();
    let body = sonic_rs::to_vec(&CrudListResponse {
        items,
        total,
        page,
        limit,
    })
    .unwrap_or_default();
    json_response(conn, body)
}

async fn query_crud_list(
    pool: &Pool,
    category: &str,
    limit: i64,
    offset: i64,
) -> Result<Vec<CrudItem>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
             FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
        )
        .await?;
    let rows = client.query(&stmt, &[&category, &limit, &offset]).await?;
    Ok(rows
        .into_iter()
        .map(|row| CrudItem {
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
        })
        .collect())
}

pub async fn crud_read(conn: Conn) -> Conn {
    let id: i32 = match conn.param("id").and_then(|s| s.parse().ok()) {
        Some(id) => id,
        None => return conn.with_status(Status::BadRequest).halt(),
    };

    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));

    if let Some(entry) = state.crud_cache.get(&id) {
        if entry.expires > Instant::now() {
            let body = entry.body.clone();
            return conn
                .with_status(Status::Ok)
                .with_response_header(KnownHeaderName::ContentType, APPLICATION_JSON)
                .with_response_header("x-cache", "HIT")
                .with_body(body)
                .halt();
        }
    }

    let Some(pool) = &state.pg else {
        return conn.with_status(Status::NotFound).halt();
    };

    let row = match query_crud_read(pool, id).await {
        Ok(Some(item)) => item,
        Ok(None) => return conn.with_status(Status::NotFound).halt(),
        Err(e) => {
            log::warn!("crud read failed: {e}");
            return conn.with_status(Status::InternalServerError).halt();
        }
    };

    let body = sonic_rs::to_vec(&row).unwrap_or_default();
    state.crud_cache.insert(
        id,
        CacheEntry {
            body: body.clone(),
            expires: Instant::now() + CRUD_CACHE_TTL,
        },
    );

    conn.with_status(Status::Ok)
        .with_response_header(KnownHeaderName::ContentType, APPLICATION_JSON)
        .with_response_header("x-cache", "MISS")
        .with_body(body)
        .halt()
}

async fn query_crud_read(
    pool: &Pool,
    id: i32,
) -> Result<Option<CrudItem>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count \
             FROM items WHERE id = $1",
        )
        .await?;
    let row = client.query_opt(&stmt, &[&id]).await?;
    Ok(row.map(|row| CrudItem {
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

#[derive(Deserialize, Serialize)]
struct CrudCreate {
    id: i32,
    name: String,
    category: String,
    price: i32,
    quantity: i32,
    #[serde(default)]
    active: bool,
    #[serde(default)]
    tags: sonic_rs::Value,
}

#[derive(Serialize)]
struct CrudCreateResponse<'a> {
    #[serde(flatten)]
    input: &'a CrudCreate,
    rating: Rating,
}

pub async fn crud_create(mut conn: Conn) -> Conn {
    let body = match conn.request_body_string().await {
        Ok(b) => b,
        Err(_) => return conn.with_status(Status::BadRequest).halt(),
    };
    let input: CrudCreate = match sonic_rs::from_str(&body) {
        Ok(x) => x,
        Err(_) => return conn.with_status(Status::UnprocessableEntity).halt(),
    };

    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));
    let Some(pool) = &state.pg else {
        return conn.with_status(Status::ServiceUnavailable).halt();
    };

    if let Err(e) = upsert_crud(pool, &input).await {
        log::warn!("crud create failed: {e}");
        return conn.with_status(Status::InternalServerError).halt();
    }

    state.crud_cache.remove(&input.id);

    let resp = CrudCreateResponse {
        input: &input,
        rating: Rating { score: 0, count: 0 },
    };
    let out = sonic_rs::to_vec(&resp).unwrap_or_default();
    conn.with_status(Status::Created)
        .with_response_header(KnownHeaderName::ContentType, APPLICATION_JSON)
        .with_body(out)
        .halt()
}

async fn upsert_crud(
    pool: &Pool,
    item: &CrudCreate,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, \
             rating_count) VALUES ($1, $2, $3, $4, $5, $6, $7::text::jsonb, 0, 0) ON CONFLICT \
             (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = \
             EXCLUDED.price, quantity = EXCLUDED.quantity, active = EXCLUDED.active, tags = \
             EXCLUDED.tags",
        )
        .await?;
    let tags = sonic_rs::to_string(&item.tags).unwrap_or_else(|_| "[]".into());
    client
        .execute(
            &stmt,
            &[
                &item.id,
                &item.name,
                &item.category,
                &item.price,
                &item.quantity,
                &item.active,
                &tags,
            ],
        )
        .await?;
    Ok(())
}

#[derive(Deserialize)]
struct CrudUpdate {
    name: Option<String>,
    price: Option<i32>,
    quantity: Option<i32>,
}

pub async fn crud_update(mut conn: Conn) -> Conn {
    let id: i32 = match conn.param("id").and_then(|s| s.parse().ok()) {
        Some(id) => id,
        None => return conn.with_status(Status::BadRequest).halt(),
    };
    let body = match conn.request_body_string().await {
        Ok(b) => b,
        Err(_) => return conn.with_status(Status::BadRequest).halt(),
    };
    let input: CrudUpdate = match sonic_rs::from_str(&body) {
        Ok(x) => x,
        Err(_) => return conn.with_status(Status::UnprocessableEntity).halt(),
    };

    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));
    let Some(pool) = &state.pg else {
        return conn.with_status(Status::ServiceUnavailable).halt();
    };

    let updated = match update_crud(pool, id, &input).await {
        Ok(Some(item)) => item,
        Ok(None) => return conn.with_status(Status::NotFound).halt(),
        Err(e) => {
            log::warn!("crud update failed: {e}");
            return conn.with_status(Status::InternalServerError).halt();
        }
    };

    state.crud_cache.remove(&id);

    let out = sonic_rs::to_vec(&updated).unwrap_or_default();
    conn.with_status(Status::Ok)
        .with_response_header(KnownHeaderName::ContentType, APPLICATION_JSON)
        .with_body(out)
        .halt()
}

async fn update_crud(
    pool: &Pool,
    id: i32,
    input: &CrudUpdate,
) -> Result<Option<CrudItem>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached(
            "UPDATE items SET name = COALESCE($2, name), price = COALESCE($3, price), quantity = \
             COALESCE($4, quantity) WHERE id = $1 RETURNING id, name, category, price, quantity, \
             active, tags, rating_score, rating_count",
        )
        .await?;
    let row = client
        .query_opt(&stmt, &[&id, &input.name, &input.price, &input.quantity])
        .await?;
    Ok(row.map(|row| CrudItem {
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
