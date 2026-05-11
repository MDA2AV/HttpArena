#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod handlers;
mod runtime;
mod state;
mod static_preload;

use crate::{
    handlers::{
        async_db, baseline_any, baseline_get, crud_create, crud_list, crud_read, crud_update,
        json_handler, pipeline, upload, ws_echo,
    },
    runtime::bind_reuseport,
    state::{AppState, SharedState, build_pg_pool},
    static_preload::StaticPreload,
};
use std::sync::Arc;
use trillium::Handler;
use trillium_compression::Compression;
use trillium_quinn::QuicConfig;
use trillium_router::Router;
use trillium_rustls::RustlsAcceptor;
use trillium_tokio::tokio;
use trillium_websockets::websocket;

fn tuned_http_config() -> trillium::HttpConfig {
    trillium::HttpConfig::default()
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
        Compression::new(),
        Router::new()
            .get("/pipeline", pipeline)
            .any(&["get", "post"], "/baseline11", baseline_any)
            .get("/baseline2", baseline_get)
            .get("/json/:count", json_handler)
            .post("/upload", upload)
            .get("/static/*", static_files)
            .get("/async-db", async_db)
            .get("/crud/items", crud_list)
            .post("/crud/items", crud_create)
            .get("/crud/items/:id", crud_read)
            .put("/crud/items/:id", crud_update)
            .get("/ws", websocket(ws_echo)),
    )
}

struct WorkerInputs {
    shared: SharedState,
    static_files: StaticPreload,
    cert: Option<Vec<u8>>,
    key: Option<Vec<u8>>,
    swansong: swansong::Swansong,
    tls_port: u16,
    workers: usize,
    is_quic_worker: bool,
}

fn run_worker(idx: usize, inputs: WorkerInputs) {
    let WorkerInputs {
        shared,
        static_files,
        cert,
        key,
        swansong,
        tls_port,
        workers,
        is_quic_worker,
    } = inputs;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current_thread runtime");

    rt.block_on(async move {
        // Build pool inside this worker's runtime so its tokio_postgres driver tasks
        // are owned by this reactor.
        let state = Arc::new(AppState {
            dataset: shared.dataset.clone(),
            crud_cache: shared.crud_cache.clone(),
            pg: build_pg_pool(workers),
        });
        let l8080 = bind_reuseport(8080).expect("bind 8080");
        log::info!("worker {idx}: bound 8080");

        // 8080: cleartext h1 + ws
        trillium_tokio::config()
            .with_prebound_server(l8080)
            .with_swansong(swansong.clone())
            .without_signals()
            .with_nodelay()
            .with_http_config(tuned_http_config())
            .with_shared_state(state.clone())
            .spawn(build_handler(static_files.clone()));

        if let (Some(cert), Some(key)) = (cert.as_deref(), key.as_deref()) {
            let l8081 = bind_reuseport(8081).expect("bind 8081");
            trillium_tokio::config()
                .with_prebound_server(l8081)
                .with_swansong(swansong.clone())
                .without_signals()
                .with_nodelay()
                .with_http_config(tuned_http_config())
                .with_shared_state(state.clone())
                .with_acceptor(RustlsAcceptor::from_single_cert_no_h2(cert, key))
                .spawn(build_handler(static_files.clone()));

            let l_tls = bind_reuseport(tls_port).expect("bind TLS port");
            let tls_cfg = trillium_tokio::config()
                .with_prebound_server(l_tls)
                .with_swansong(swansong.clone())
                .without_signals()
                .with_nodelay()
                .with_http_config(tuned_http_config())
                .with_shared_state(state.clone())
                .with_acceptor(RustlsAcceptor::from_single_cert(cert, key));

            if is_quic_worker {
                tls_cfg
                    .with_quic(QuicConfig::from_single_cert(cert, key))
                    .spawn(build_handler(static_files.clone()));
                log::info!("worker {idx}: bound TLS + QUIC on {tls_port}");
            } else {
                tls_cfg.spawn(build_handler(static_files.clone()));
                log::info!("worker {idx}: bound TLS on {tls_port}");
            }
        } else if idx == 0 {
            log::warn!("TLS cert/key not found; only port 8080 is listening");
        }

        swansong.await;
    });
}

fn main() {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    let shared = SharedState::init();

    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    let static_files = StaticPreload::load(&static_dir);

    let cert =
        std::fs::read(std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".into()))
            .ok();
    let key =
        std::fs::read(std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".into())).ok();

    let tls_port: u16 = std::env::var("TLS_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8443);

    let n_workers: usize = std::env::var("WORKERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(num_cpus::get)
        .max(1);

    let swansong = swansong::Swansong::new();

    // Signal handler runs in its own OS thread (blocking iterator API), drives swansong on signal.
    {
        let swansong = swansong.clone();
        std::thread::Builder::new()
            .name("signals".into())
            .spawn(move || {
                let mut signals = signal_hook::iterator::Signals::new([
                    signal_hook::consts::SIGINT,
                    signal_hook::consts::SIGTERM,
                ])
                .expect("install signal handler");
                if signals.forever().next().is_some() {
                    log::info!("shutdown signal received");
                    swansong.shut_down();
                }
            })
            .expect("spawn signal thread");
    }

    log::info!("starting {n_workers} workers");

    let mut handles = Vec::with_capacity(n_workers);
    for idx in 0..n_workers {
        let inputs = WorkerInputs {
            shared: shared.clone(),
            static_files: static_files.clone(),
            cert: cert.clone(),
            key: key.clone(),
            swansong: swansong.clone(),
            tls_port,
            workers: n_workers,
            is_quic_worker: idx == 0,
        };
        handles.push(
            std::thread::Builder::new()
                .name(format!("worker-{idx}"))
                .spawn(move || run_worker(idx, inputs))
                .expect("spawn worker thread"),
        );
    }

    for h in handles {
        h.join().expect("worker join");
    }
}
