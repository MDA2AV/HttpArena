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

/// Build a fresh per-worker `Client`. Cross-runtime sharing of pooled connections is risky
/// (tokio I/O resources are tied to the runtime that opened them), so each worker gets its
/// own pool. h2/h3 multiplex hundreds of streams per upstream connection, so the upstream
/// connection-count multiplier here is fine.
fn build_client() -> Client {
    let rustls_client = upstream_rustls_config();
    let quic_client = ClientQuicConfig::from_rustls_client_config(rustls_client.clone());
    let rustls_layer = RustlsConfig::new(rustls_client, ClientConfig::default());
    Client::new_with_quic(rustls_layer, quic_client)
}

fn build_handler() -> impl Handler {
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    let upstream =
        std::env::var("PROXY_UPSTREAM").unwrap_or_else(|_| "https://localhost:9443".into());

    (
        Router::new().get("/static/*", files(static_dir)),
        Proxy::new(build_client(), upstream).with_via_pseudonym("trillium-proxy"),
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
    enable_h3: bool,
    is_quic_worker: bool,
    swansong: swansong::Swansong,
}

fn run_worker(idx: usize, inputs: WorkerInputs) {
    let WorkerInputs {
        cert,
        key,
        port,
        enable_h3,
        is_quic_worker,
        swansong,
    } = inputs;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current_thread runtime");

    rt.block_on(async move {
        let listener = bind_reuseport(port).expect("bind proxy port");
        log::info!("worker {idx}: bound {port} (h3={})", enable_h3 && is_quic_worker);

        let config = trillium_tokio::config()
            .with_prebound_server(listener)
            .with_swansong(swansong.clone())
            .without_signals()
            .with_nodelay()
            .with_acceptor(RustlsAcceptor::from_single_cert(&cert, &key));

        if enable_h3 && is_quic_worker {
            config
                .with_quic(QuicConfig::from_single_cert(&cert, &key))
                .spawn(build_handler());
        } else {
            config.spawn(build_handler());
        }

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

    log::info!("proxy starting {n_workers} workers (port={port}, h3={enable_h3})");

    let mut handles = Vec::with_capacity(n_workers);
    for idx in 0..n_workers {
        let inputs = WorkerInputs {
            cert: cert.clone(),
            key: key.clone(),
            port,
            enable_h3,
            is_quic_worker: idx == 0,
            swansong: swansong.clone(),
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
