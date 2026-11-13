pub mod common;

use httparena_sark::db::{self, BodyError, Update};
use sark_json::parsing::Request;

#[test]
fn database_and_cache_budgets_are_admitted() {
    let connections = std::num::NonZero::new(db::TASKS).expect("database task capacity");
    let waiters = connections.saturating_add(1);
    db::pg_config(connections, waiters, true).expect("database limits");
    httparena_sark::cache::config(waiters, true).expect("cache limits");
}

#[test]
fn database_rows_keep_json_types_and_admit_tags() {
    assert_eq!(
        db::item_json(common::database::item(common::database::TAGS))
            .expect("item response")
            .as_ref(),
        common::database::ITEM,
    );
    assert!(matches!(
        db::item_json(common::database::item("[")),
        Err(BodyError::Json(_)),
    ));
}

#[test]
fn update_schema_preserves_signed_database_integers() {
    let update = <Update as Request>::decode(common::database::UPDATE).expect("update");
    assert_eq!(update.name.as_str(), "updated \"item\"");
    assert_eq!(
        db::update_values(update.price, update.quantity).expect("database integers"),
        (-111, 22)
    );
    let overflow =
        <Update as Request>::decode(common::database::PRICE_OVERFLOW).expect("JSON integer");
    assert!(db::update_values(overflow.price, overflow.quantity).is_err());
}

#[test]
fn fortunes_append_sort_and_escape_at_render_time() {
    assert_eq!(
        db::render_fortunes(common::database::fortunes()).expect("fortune page"),
        common::database::HTML.as_bytes(),
    );
    let message = common::database::oversized_fortune();
    assert!(matches!(
        db::render_fortunes(vec![(1, &message)]),
        Err(BodyError::Limit { .. }),
    ));
}

#[test]
#[ignore = "requires seeded disposable PostgreSQL and Redis"]
fn database_updates_reach_item_and_range_responses() {
    let pair = dope_test::harness::server::Pair::bind().expect("HTTP listener");
    let mut worker = common::http::worker(pair.addr());
    worker.boot.database_url =
        Some(std::env::var("HTTPARENA_TEST_DATABASE_URL").expect("isolated PostgreSQL URL"));
    worker.boot.redis_url =
        Some(std::env::var("HTTPARENA_TEST_REDIS_URL").expect("isolated Redis URL"));
    pair.run(
        move |context, http| {
            httparena_sark::runtime::serve(
                worker,
                context,
                httparena_sark::runtime::Bindings {
                    http: Some(http),
                    ..Default::default()
                },
            )
            .map(drop)
        },
        |address| {
            assert_eq!(
                common::http::request(address, "/api/items/7", Some(common::database::UPDATE),),
                (204, Vec::new()),
            );
            assert_eq!(
                common::http::request(address, "/api/items/7", None),
                (200, common::database::UPDATED_ROW.to_vec()),
            );
            assert_eq!(
                common::http::request(address, "/async-db?min=-111&max=-111&limit=50", None,),
                (200, common::database::updated_range()),
            );
        },
    )
    .expect("database application");
}

#[test]
#[ignore = "requires seeded disposable PostgreSQL and Redis"]
fn user_cache_keeps_identity_and_fixed_expiration() {
    use std::time::{Duration, Instant};

    let pair = dope_test::harness::server::Pair::bind()
        .expect("HTTP listener")
        .timeouts(Duration::from_secs(2), Duration::from_secs(45))
        .expect("cache test deadline");
    let mut worker = common::http::worker(pair.addr());
    worker.boot.database_url =
        Some(std::env::var("HTTPARENA_TEST_DATABASE_URL").expect("isolated PostgreSQL URL"));
    worker.boot.redis_url =
        Some(std::env::var("HTTPARENA_TEST_REDIS_URL").expect("isolated Redis URL"));
    let redis = std::env::var("HTTPARENA_TEST_REDIS_CONTAINER").expect("isolated Redis container");
    pair.run(
        move |context, http| {
            httparena_sark::runtime::serve(
                worker,
                context,
                httparena_sark::runtime::Bindings {
                    http: Some(http),
                    ..Default::default()
                },
            )
            .map(drop)
        },
        |address| {
            let first = common::http::request_headers(address, "/api/me", None, &["x-user-id: 42"]);
            assert_eq!(first.0, 200);
            let admitted = Instant::now();
            common::database::redis(&redis, &["SET", "user:42", "["]);
            common::database::redis(&redis, &["SET", "user:8", r#"{"id":8}"#]);
            assert_eq!(
                common::http::request_headers(address, "/api/me", None, &["x-user-id: 8"]),
                (200, br#"{"id":8}"#.to_vec()),
            );
            std::thread::sleep(Duration::from_secs(20).saturating_sub(admitted.elapsed()));
            assert_eq!(
                common::http::request_headers(address, "/api/me", None, &["x-user-id: 42"]),
                first,
            );
            std::thread::sleep(Duration::from_secs(31).saturating_sub(admitted.elapsed()));
            assert_eq!(
                common::http::request_headers(address, "/api/me", None, &["x-user-id: 42"]),
                (502, b"response encoding failed".to_vec()),
            );
        },
    )
    .expect("cached user application");
}
