#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod grpc;
mod handlers;
mod state;
mod static_preload;

use env_logger::Env;
use grpc::{Benchmark, BenchmarkServiceServer};
use handlers::{
    async_db, baseline_any, baseline_get, crud_create, crud_list, crud_read, crud_update, fortunes,
    json_handler, pipeline, upload, ws_echo,
};
use state::{AppState, SharedState, build_pg_pool};
use static_preload::StaticPreload;
use std::{env, error::Error, fs, sync::Arc};
use trillium::{Handler, HttpConfig, Method};
use trillium_compression::Compression;
use trillium_quinn::QuicConfig;
use trillium_router::Router;
use trillium_rustls::RustlsAcceptor;
use trillium_tokio::config;
use trillium_websockets::websocket;

fn tuned_http_config() -> HttpConfig {
    HttpConfig::default()
        .with_response_buffer_len(8192)
        .with_received_body_max_len(32 * 1024 * 1024)
        .with_received_body_initial_len(64 * 1024)
        .with_received_body_max_preallocate(32 * 1024 * 1024)
        .with_copy_loops_per_yield(64)
        .with_h2_max_frame_size(65536)
        .with_request_buffer_initial_len(256)
}

fn build_handler(static_files: StaticPreload) -> impl Handler {
    (
        BenchmarkServiceServer::new(Benchmark),
        Compression::new(),
        Router::new()
            .get("/pipeline", pipeline)
            .any(&[Method::Get, Method::Post], "/baseline11", baseline_any)
            .get("/baseline2", baseline_get)
            .get("/json/:count", json_handler)
            .post("/upload", upload)
            .get("/static/*", static_files)
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

    let shared = SharedState::init();

    let static_dir = env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    let static_files = StaticPreload::load(&static_dir);

    let cert = fs::read(env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".into())).ok();
    let key = fs::read(env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".into())).ok();

    let tls_port: u16 = env::var("TLS_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8443);

    let n_workers: usize = env::var("WORKERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(num_cpus::get)
        .max(1);

    let state = Arc::new(AppState {
        dataset: shared.dataset.clone(),
        crud_cache: shared.crud_cache.clone(),
        pg: build_pg_pool(),
    });

    let mut builder = config()
        .with_nodelay()
        .with_http_config(tuned_http_config())
        .with_shared_state(state)
        .listeners()
        .with_reuseport_workers(n_workers)
        .bind_reuseport_tcp(8080)?;

    if let Ok(uds) = env::var("LISTEN_UDS") {
        let _ = std::fs::remove_file(&uds);
        builder = builder.bind_uds(uds)?;
    }

    if let (Some(cert), Some(key)) = (cert.as_deref(), key.as_deref()) {
        builder = builder
            .bind_reuseport_tls(8081, RustlsAcceptor::from_single_cert_no_h2(cert, key))?
            .bind_reuseport_tls(tls_port, RustlsAcceptor::from_single_cert(cert, key))?
            .bind_quic(tls_port, QuicConfig::from_single_cert(cert, key))?;
    } else {
        log::warn!("TLS cert/key not found; only port 8080 is listening");
    }

    log::info!(
        "starting trillium-tuned via server(): {n_workers} reuseport worker(s) + shared runtime \
         for h3"
    );

    builder.run(build_handler(static_files));
    Ok(())
}
