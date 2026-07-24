#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod grpc;
mod handlers;
mod state;

use env_logger::Env;
use grpc::{Benchmark, BenchmarkServiceServer};
use handlers::{
    async_db, baseline_any, baseline_get, crud_create, crud_list, crud_read, crud_update, fortunes,
    json_handler, pipeline, upload, ws_echo,
};
use state::AppState;
use std::{env, error::Error, fs};
use trillium::{Handler, HttpConfig, Method};
use trillium_compression::Compression;
use trillium_quinn::QuicConfig;
use trillium_router::Router;
use trillium_rustls::RustlsAcceptor;
use trillium_static::StaticFileHandler;
use trillium_tokio::config;
use trillium_websockets::websocket;

fn build_handler() -> impl Handler {
    let static_dir = env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    (
        BenchmarkServiceServer::new(Benchmark),
        Compression::new(),
        Router::new()
            .get("/pipeline", pipeline)
            .any(&[Method::Get, Method::Post], "/baseline11", baseline_any)
            .get("/baseline2", baseline_get)
            .get("/json/:count", json_handler)
            .post("/upload", upload)
            .get(
                "/static/*",
                StaticFileHandler::new(static_dir).with_precompressed(),
            )
            .get("/async-db", async_db)
            .get("/fortunes", fortunes)
            .get("/crud/items", crud_list)
            .post("/crud/items", crud_create)
            .get("/crud/items/:id", crud_read)
            .put("/crud/items/:id", crud_update)
            .get("/ws", websocket(ws_echo)),
    )
}

fn main() -> Result<(), Box<dyn Error>> {
    env_logger::init_from_env(Env::default().default_filter_or("info"));

    let state = AppState::init();

    let cert = fs::read(env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".into())).ok();
    let key = fs::read(env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".into())).ok();

    let tls_port: u16 = env::var("TLS_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8443);

    let http_config = HttpConfig::default().with_received_body_max_len(32 * 1024 * 1024);

    let mut builder = config()
        .with_nodelay()
        .with_http_config(http_config)
        .with_shared_state(state)
        .listeners()
        .bind_tcp(8080)?;

    if let Ok(uds) = env::var("LISTEN_UDS") {
        let _ = std::fs::remove_file(&uds);
        builder = builder.bind_uds(uds)?;
    }

    if let (Some(cert), Some(key)) = (cert.as_deref(), key.as_deref()) {
        builder = builder
            .bind_tls(8081, RustlsAcceptor::from_single_cert_no_h2(cert, key))?
            .bind_tls(tls_port, RustlsAcceptor::from_single_cert(cert, key))?
            .bind_quic(tls_port, QuicConfig::from_single_cert(cert, key))?;
    } else {
        log::warn!("TLS cert/key not found; only port 8080 is listening");
    }

    builder.run(build_handler());
    Ok(())
}
