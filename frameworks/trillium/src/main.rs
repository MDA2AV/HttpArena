#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod handlers;
mod state;

use crate::{
    handlers::{
        async_db, baseline_any, baseline_get, crud_create, crud_list, crud_read, crud_update,
        json_handler, pipeline, upload, ws_echo,
    },
    state::AppState,
};
use trillium::Handler;
use trillium_compression::Compression;
use trillium_quinn::QuicConfig;
use trillium_router::Router;
use trillium_rustls::RustlsAcceptor;
use trillium_static::files;
use trillium_tokio::tokio;
use trillium_websockets::websocket;

fn build_handler() -> impl Handler {
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    (
        Compression::new(),
        Router::new()
            .get("/pipeline", pipeline)
            .any(&["get", "post"], "/baseline11", baseline_any)
            .get("/baseline2", baseline_get)
            .get("/json/:count", json_handler)
            .post("/upload", upload)
            .get("/static/*", files(static_dir))
            .get("/async-db", async_db)
            .get("/crud/items", crud_list)
            .post("/crud/items", crud_create)
            .get("/crud/items/:id", crud_read)
            .put("/crud/items/:id", crud_update)
            .get("/ws", websocket(ws_echo)),
    )
}

fn main() {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    let state = AppState::init();

    let cert =
        std::fs::read(std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".into()))
            .ok();
    let key =
        std::fs::read(std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".into())).ok();

    let http_config = trillium::HttpConfig::default().with_received_body_max_len(32 * 1024 * 1024);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();

    let swansong = swansong::Swansong::new();

    runtime.block_on(async move {
        if let (Some(cert), Some(key)) = (cert.as_deref(), key.as_deref()) {
            let tls_port: u16 = std::env::var("TLS_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(8443);

            // 8081: h1 only over TLS (ALPN http/1.1) — for json-tls
            trillium_tokio::config()
                .with_port(8081)
                .with_host("0.0.0.0")
                .with_nodelay()
                .with_swansong(swansong.clone())
                .without_signals()
                .with_http_config(http_config)
                .with_shared_state(state.clone())
                .with_acceptor(RustlsAcceptor::from_single_cert_no_h2(cert, key))
                .spawn(build_handler());

            // TLS_PORT (default 8443): h1 + h2 over TLS, plus h3 over QUIC
            trillium_tokio::config()
                .with_port(tls_port)
                .with_host("0.0.0.0")
                .with_nodelay()
                .with_swansong(swansong.clone())
                .without_signals()
                .with_http_config(http_config)
                .with_shared_state(state.clone())
                .with_acceptor(RustlsAcceptor::from_single_cert(cert, key))
                .with_quic(QuicConfig::from_single_cert(cert, key))
                .spawn(build_handler());
        } else {
            log::warn!("TLS cert/key not found; only port 8080 is listening");
        }

        // 8080: h1 cleartext (also serves /ws and h2c-prior-knowledge); registers signal handlers
        trillium_tokio::config()
            .with_port(8080)
            .with_host("0.0.0.0")
            .with_nodelay()
            .with_swansong(swansong.clone())
            .with_http_config(http_config)
            .with_shared_state(state.clone())
            .spawn(build_handler());

        swansong.await
    });
}
