//! HttpArena entry for Roxygen, Meta's HTTP/1.1 and HTTP/2 library for Rust.
//!
//! Two `HttpServer`s share one process: prior-knowledge h2c on 8082 and HTTP/2
//! over TLS on 8443. Each runs one worker thread per CPU in the container's
//! affinity mask, and both use Roxygen's owned HTTP/2 driver, which polls every
//! stream of a connection from one future instead of running a task per request.

mod handler;

use std::io;
use std::mem::MaybeUninit;
use std::net::Ipv6Addr;
use std::path::Path;
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use roxygen_codec::CodecSetting;
use roxygen_core::handler::HttpHandlerRef;
use roxygen_core::http::CodecProtocol;
use roxygen_server::acceptor::ServerSessionConfig;
use roxygen_server::server::HandlerFactory;
use roxygen_server::server::HttpServer;
use roxygen_server::server::ServerConfig;
use roxygen_server::server::ServerSocketConfig;
use roxygen_server::server::StaticTlsCredentials;
use roxygen_server::server::TlsCredentialProvider;
use roxygen_transport::tls::TlsServerOptions;
use rustls::CipherSuite;
use rustls::ServerConfig as RustlsConfig;
use rustls::crypto::ring;
use rustls::pki_types::CertificateDer;
use rustls::pki_types::PrivateKeyDer;
use rustls::pki_types::pem::PemObject;

use crate::handler::Arena;
use crate::handler::Handler;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

const H2C_PORT: u16 = 8082;
const TLS_PORT: u16 = 8443;
const CERT: &str = "/certs/server.crt";
const KEY: &str = "/certs/server.key";
const DATASET: &str = "/data/dataset.json";
const STATIC_DIR: &str = "/data/static";

const COMMAND_CAPACITY: usize = 16_384;
const BACKLOG: i32 = 65_535;
const MAX_CONCURRENT_STREAMS: u64 = 1_024;
const STREAM_WINDOW: u32 = 1 << 20;
const CONNECTION_WINDOW: u32 = 10 << 20;

fn session_config() -> ServerSessionConfig {
    // MAX_HEADER_LIST_SIZE, HEADER_TABLE_SIZE, MAX_FRAME_SIZE,
    // MAX_CONCURRENT_STREAMS and INITIAL_WINDOW_SIZE.
    let settings = [
        (6, 32_768),
        (1, 4_096),
        (5, 16_384),
        (3, MAX_CONCURRENT_STREAMS),
        (4, u64::from(STREAM_WINDOW)),
    ]
    .into_iter()
    .map(|(identifier, value)| CodecSetting { identifier, value })
    .collect();
    ServerSessionConfig {
        settings,
        stream_flow_control: STREAM_WINDOW,
        connection_flow_control: CONNECTION_WINDOW,
        stream_read_timeout: Duration::ZERO,
        connection_idle_timeout: Duration::ZERO,
        write_timeout: Duration::ZERO,
        owned_http2: true,
        verbatim_http2_header_values: true,
        add_date_header_to_response: false,
        ..ServerSessionConfig::default()
    }
}

fn tls_config() -> io::Result<RustlsConfig> {
    let invalid = |context: &str, error: &dyn std::fmt::Display| {
        io::Error::new(io::ErrorKind::InvalidData, format!("{context}: {error}"))
    };
    let certs = CertificateDer::pem_file_iter(CERT)
        .and_then(Iterator::collect::<Result<Vec<_>, _>>)
        .map_err(|error| invalid("certificate", &error))?;
    let key = PrivateKeyDer::from_pem_file(KEY).map_err(|error| invalid("key", &error))?;

    // The default suites, with AES-128-GCM first so the server's preference picks it.
    let mut provider = ring::default_provider();
    provider
        .cipher_suites
        .sort_by_key(|suite| suite.suite() != CipherSuite::TLS13_AES_128_GCM_SHA256);
    let mut config = RustlsConfig::builder_with_provider(Arc::new(provider))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|error| invalid("TLS versions", &error))?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|error| invalid("TLS certificate", &error))?;
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    config.ignore_client_order = true;
    config.ticketer = ring::Ticketer::new().map_err(|error| invalid("TLS ticketer", &error))?;
    Ok(config)
}

/// The number of CPUs in this process's affinity mask.
fn available_cpus() -> usize {
    // SAFETY: `set` is a zeroed `cpu_set_t` that `sched_getaffinity` fills in.
    unsafe {
        let mut set: libc::cpu_set_t = MaybeUninit::zeroed().assume_init();
        if libc::sched_getaffinity(0, size_of::<libc::cpu_set_t>(), &mut set) != 0 {
            return 1;
        }
        libc::CPU_COUNT(&set).max(1) as usize
    }
}

fn start(
    port: u16,
    tls: Option<Arc<dyn TlsCredentialProvider>>,
    arena: &'static Arena,
    workers: usize,
) -> io::Result<HttpServer> {
    let config = ServerConfig {
        socket: ServerSocketConfig {
            bind_addresses: vec![(Ipv6Addr::UNSPECIFIED, port).into()],
            backlog: BACKLOG,
            ..ServerSocketConfig::default()
        },
        plaintext_protocol: CodecProtocol::Http2,
        session: session_config(),
        num_io_threads: workers,
        command_capacity: COMMAND_CAPACITY,
        shutdown_on_signals: Vec::new(),
        tls_credentials: tls,
        ..ServerConfig::default()
    };
    let handlers: HandlerFactory =
        Arc::new(move |_| Rc::new(Handler::new(arena)) as HttpHandlerRef);
    HttpServer::start(config, handlers, None).map_err(|error| io::Error::other(error.to_string()))
}

fn run() -> io::Result<()> {
    let arena: &'static Arena = Box::leak(Box::new(Arena::load(
        Path::new(DATASET),
        Path::new(STATIC_DIR),
    )?));
    let workers = available_cpus();
    let tls: Arc<dyn TlsCredentialProvider> = Arc::new(StaticTlsCredentials::new(
        TlsServerOptions::from_rustls_config(tls_config()?),
    ));

    // Worker threads inherit this mask, so only the main thread takes the signal.
    // SAFETY: plain sigset manipulation on a local set.
    let signals = unsafe {
        let mut set: libc::sigset_t = MaybeUninit::zeroed().assume_init();
        libc::sigemptyset(&mut set);
        libc::sigaddset(&mut set, libc::SIGTERM);
        libc::sigaddset(&mut set, libc::SIGINT);
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
        set
    };

    let _h2c = start(H2C_PORT, None, arena, workers)?;
    let _tls = start(TLS_PORT, Some(tls), arena, workers)?;
    eprintln!("roxygen-arena: h2c :{H2C_PORT} tls :{TLS_PORT} workers={workers}");

    let mut signal = 0;
    // SAFETY: `signals` is initialized above and blocked on this thread.
    unsafe { libc::sigwait(&signals, &mut signal) };
    // The harness stops the container after each run, so nothing needs draining.
    std::process::exit(0);
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("roxygen-arena: {error}");
            ExitCode::FAILURE
        }
    }
}
