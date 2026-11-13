pub mod common;

use std::net::{Ipv6Addr, SocketAddr};

use cartel_pg::{ConfigError, ConfigField};
use httparena_sark::boot::UrlError;
use url::SyntaxViolation;

#[test]
fn startup_urls_preserve_ipv6_ports_and_redis_database() {
    let boot = common::boot::settings(
        Some("postgresql://be%6ech:be%6ech@[::1]:5433/bench%6dark?sslmode=disable"),
        Some("redis://bench:p%40ss@[::1]:6380/%32"),
    );
    assert_eq!(
        boot.postgres()
            .map(|(address, _)| address)
            .expect("Postgres"),
        Some(SocketAddr::from((Ipv6Addr::LOCALHOST, 5433))),
    );
    let (address, plan) = boot.redis().expect("Redis");
    assert_eq!(address, Some(SocketAddr::from((Ipv6Addr::LOCALHOST, 6380))));
    assert_eq!(plan.database(), Some(2));
}

#[test]
fn startup_urls_preserve_native_credential_rejection() {
    let boot = common::boot::settings(
        Some("postgres://be%00nch:bench@127.0.0.1/benchmark"),
        Some("redis://127.0.0.1"),
    );
    assert!(matches!(
        boot.postgres(),
        Err(UrlError::Postgres(ConfigError::Nul {
            field: ConfigField::User,
            position: 2,
        })),
    ));
    let (address, plan) = boot.redis().expect("Redis defaults");
    assert_eq!(address, Some(SocketAddr::from(([127, 0, 0, 1], 6379))));
    assert_eq!(plan.database(), None);
}

#[test]
fn startup_urls_reject_unsupported_options_and_malformed_escapes() {
    let mut boot = common::boot::settings(
        Some("postgres://bench:bench@127.0.0.1/benchmark?sslmode=require"),
        Some("redis://127.0.0.1?protocol=resp3"),
    );
    assert!(matches!(boot.postgres(), Err(UrlError::Option(name)) if name == "sslmode"));
    assert!(matches!(boot.redis(), Err(UrlError::Option(name)) if name == "protocol"));
    boot.database_url = Some("postgres://bench:%XX@127.0.0.1/benchmark".into());
    assert!(matches!(
        boot.postgres(),
        Err(UrlError::Syntax(SyntaxViolation::PercentDecode)),
    ));
    boot.redis_url = Some("rediss://127.0.0.1/0".into());
    assert!(matches!(boot.redis(), Err(UrlError::Scheme(scheme)) if scheme == "rediss"));
    boot.redis_url = Some("redis://127.0.0.1:0".into());
    assert!(matches!(boot.redis(), Err(UrlError::ZeroPort)));
}

#[test]
fn startup_urls_reject_multiple_database_components_before_normalization() {
    let boot = common::boot::settings(
        Some("postgres://bench:bench@127.0.0.1/benchmark/.."),
        Some("redis://127.0.0.1/1/%2e%2e/2"),
    );
    assert!(matches!(boot.postgres(), Err(UrlError::DatabasePath)));
    assert!(matches!(boot.redis(), Err(UrlError::DatabasePath)));
}

#[test]
fn absent_upstreams_do_not_create_endpoints() {
    let boot = common::boot::settings(None, None);
    assert_eq!(
        boot.postgres()
            .map(|(address, _)| address)
            .expect("Postgres"),
        None,
    );
    let (address, plan) = boot.redis().expect("Redis");
    assert_eq!(address, None);
    assert_eq!(plan.database(), None);
}
