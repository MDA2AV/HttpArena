#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
};

use socket2::{Domain, SockAddr, Socket, Type};
use trillium::Handler;
use trillium_proxy::{Client, Proxy};
use trillium_quinn::{ClientQuicConfig, QuicConfig};
use trillium_router::Router;
use trillium_rustls::{
    RustlsAcceptor, RustlsConfig,
    futures_rustls::rustls::{
        self, DigitallySignedStruct, SignatureScheme,
        client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
        crypto::{
            CryptoProvider, aws_lc_rs, verify_tls12_signature, verify_tls13_signature,
        },
        pki_types::{CertificateDer, ServerName, UnixTime},
    },
};
use trillium_static::files;
use trillium_tokio::{ClientConfig, tokio, tokio::net::TcpListener};

const LISTEN_BACKLOG: i32 = 4096;

#[derive(Debug)]
struct AcceptAnyServerCert(Arc<CryptoProvider>);

impl ServerCertVerifier for AcceptAnyServerCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

fn upstream_rustls_config() -> rustls::ClientConfig {
    let provider = Arc::new(aws_lc_rs::default_provider());
    let verifier = Arc::new(AcceptAnyServerCert(provider.clone()));
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("crypto provider supports default protocol versions")
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    config
}

/// Build a fresh `Client` for the runtime currently calling this fn. The Client's pool opens
/// upstream connections via the calling runtime's reactor; tasks awaiting those connections
/// must run on the same runtime, so each worker / MT runtime gets its own.
fn build_client() -> Client {
    let rustls_client = upstream_rustls_config();
    let quic_client = ClientQuicConfig::from_rustls_client_config(rustls_client.clone());
    let rustls_layer = RustlsConfig::new(rustls_client, ClientConfig::default());
    Client::new_with_quic(rustls_layer, quic_client)
}

fn build_handler(client: Client, upstream: String, static_dir: String) -> impl Handler {
    (
        Router::new().get("/static/*", files(static_dir)),
        Proxy::new(client, upstream).with_via_pseudonym("trillium-proxy"),
    )
}

fn bind_reuseport(port: u16) -> io::Result<TcpListener> {
    let addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, port));
    let socket = Socket::new(Domain::IPV4, Type::STREAM, None)?;
    #[cfg(unix)]
    socket.set_reuse_port(true)?;
    socket.set_reuse_address(true)?;
    socket.set_nodelay(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(addr))?;
    socket.listen(LISTEN_BACKLOG)?;
    let std_listener: std::net::TcpListener = socket.into();
    TcpListener::from_std(std_listener)
}

struct WorkerInputs {
    cert: Vec<u8>,
    key: Vec<u8>,
    port: u16,
    upstream: String,
    static_dir: String,
    swansong: swansong::Swansong,
}

/// Per-worker current_thread runtime: TCP-only proxy (h1, h2). No QUIC.
fn run_worker(idx: usize, inputs: WorkerInputs) {
    let WorkerInputs {
        cert,
        key,
        port,
        upstream,
        static_dir,
        swansong,
    } = inputs;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current_thread runtime");

    rt.block_on(async move {
        let listener = bind_reuseport(port).expect("bind proxy port");
        let client = build_client();
        log::info!("proxy worker {idx}: bound TCP on {port}");

        trillium_tokio::config()
            .with_prebound_server(listener)
            .with_swansong(swansong.clone())
            .without_signals()
            .with_nodelay()
            .with_acceptor(RustlsAcceptor::from_single_cert(&cert, &key))
            .spawn(build_handler(client, upstream, static_dir));

        swansong.await;
    });
}

struct QuicRuntimeInputs {
    cert: Vec<u8>,
    key: Vec<u8>,
    port: u16,
    upstream: String,
    static_dir: String,
    n_threads: usize,
    swansong: swansong::Swansong,
}

/// Dedicated multi-thread runtime: TCP reuseport participant on `port` plus the QUIC endpoint.
/// h3 stream tasks spawned by quinn's accept loop spread across `n_threads` threads via tokio's
/// work-stealing scheduler. The per-worker current_thread runtimes still absorb most TCP traffic
/// (kernel reuseport hash gives the MT runtime ~1/(N+1) of TCP), preserving per-core hot caches.
fn run_quic_runtime(inputs: QuicRuntimeInputs) {
    let QuicRuntimeInputs {
        cert,
        key,
        port,
        upstream,
        static_dir,
        n_threads,
        swansong,
    } = inputs;

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(n_threads)
        .enable_all()
        .thread_name("quic-mt")
        .build()
        .expect("build quic multi_thread runtime");

    rt.block_on(async move {
        let listener = bind_reuseport(port).expect("bind proxy port on quic runtime");
        let client = build_client();
        log::info!("proxy quic-mt runtime: bound TCP + QUIC on {port} ({n_threads} threads)");

        trillium_tokio::config()
            .with_prebound_server(listener)
            .with_swansong(swansong.clone())
            .without_signals()
            .with_nodelay()
            .with_acceptor(RustlsAcceptor::from_single_cert(&cert, &key))
            .with_quic(QuicConfig::from_single_cert(&cert, &key))
            .spawn(build_handler(client, upstream, static_dir));

        swansong.await;
    });
}

fn main() {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    let cert =
        std::fs::read(std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".into()))
            .expect("TLS_CERT not readable");
    let key = std::fs::read(std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".into()))
        .expect("TLS_KEY not readable");

    let port: u16 = std::env::var("PROXY_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8443);
    let enable_h3 = std::env::var("PROXY_H3").is_ok_and(|v| v != "0" && !v.is_empty());

    let n_workers: usize = std::env::var("WORKERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(num_cpus::get)
        .max(1);

    // Default the QUIC runtime size proportionally to N, capped at 8 (Zen2/3/4 CCX size = 4
    // physical cores / 8 SMT threads — keeping the MT runtime ≤1 CCX worth keeps h3 work
    // L3-local and avoids paying the ~70-cycle inter-CCX hop on every steal). Override with
    // QUIC_THREADS for tuning.
    //
    // Empirical 8-core measurements: Q=2 preserves full per-worker TCP performance (≤3% delta)
    // while doubling h3 capacity over the previous worker-0-only design. Q=8 maximizes h3 (~4
    // cores' worth) at a 12-17% TCP cost. The proportional default lands users near the Q=2
    // point on small boxes and the Q=8 point on the bench machine.
    let quic_threads: usize = std::env::var("QUIC_THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| (n_workers / 4).max(2).min(8))
        .max(1);

    let upstream =
        std::env::var("PROXY_UPSTREAM").unwrap_or_else(|_| "https://localhost:9443".into());
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());

    let swansong = swansong::Swansong::new();

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

    if enable_h3 {
        log::info!(
            "proxy starting: {n_workers} per-worker current_thread workers (TCP) + 1 quic-mt runtime ({quic_threads} threads, h3 enabled, port={port})"
        );
    } else {
        log::info!(
            "proxy starting: {n_workers} per-worker current_thread workers (TCP, port={port})"
        );
    }

    let mut handles = Vec::with_capacity(n_workers + 1);

    for idx in 0..n_workers {
        let inputs = WorkerInputs {
            cert: cert.clone(),
            key: key.clone(),
            port,
            upstream: upstream.clone(),
            static_dir: static_dir.clone(),
            swansong: swansong.clone(),
        };
        handles.push(
            std::thread::Builder::new()
                .name(format!("worker-{idx}"))
                .spawn(move || run_worker(idx, inputs))
                .expect("spawn worker thread"),
        );
    }

    if enable_h3 {
        let inputs = QuicRuntimeInputs {
            cert: cert.clone(),
            key: key.clone(),
            port,
            upstream: upstream.clone(),
            static_dir: static_dir.clone(),
            n_threads: quic_threads,
            swansong: swansong.clone(),
        };
        handles.push(
            std::thread::Builder::new()
                .name("quic-mt-driver".into())
                .spawn(move || run_quic_runtime(inputs))
                .expect("spawn quic-mt driver thread"),
        );
    }

    for h in handles {
        h.join().expect("worker join");
    }
}
