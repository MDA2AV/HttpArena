use std::{convert::Infallible, io, path::Path};

use ntex::{http, service::ServiceFactory};
use ntex_grpc::server;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};

mod benchmark;
use benchmark::{SumReply, SumRequest};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[derive(Clone)]
struct BenchmarkServer;

#[server(crate::benchmark::BenchmarkService)]
impl BenchmarkServer {
    #[method(GetSum)]
    async fn get_sum(&self, req: SumRequest) -> SumReply {
        SumReply {
            result: req.a.wrapping_add(req.b),
        }
    }
}

impl ServiceFactory<(), server::ServerRequest> for BenchmarkServer {
    type Res = server::ServerResponse;
    type Error = server::ServerError;
    type Service = BenchmarkServer;
    type InitError = Infallible;

    async fn create(&self, (): &()) -> Result<Self::Service, Self::InitError> {
        Ok(BenchmarkServer)
    }
}

fn load_tls_config(cert: &Path, key: &Path) -> io::Result<rustls::ServerConfig> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let certs = CertificateDer::pem_file_iter(cert)
        .and_then(|certs| certs.collect::<Result<Vec<_>, _>>())
        .map_err(io::Error::other)?;
    let key = PrivateKeyDer::from_pem_file(key).map_err(io::Error::other)?;
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(io::Error::other)?;
    // gRPC requires HTTP/2, so `h2` is the only protocol offered.
    tls.alpn_protocols = vec![b"h2".to_vec()];
    Ok(tls)
}

#[ntex::main]
async fn main() -> io::Result<()> {
    // ntex starts one worker per available CPU; each serves h2c with prior
    // knowledge, so the first bytes on a connection are the h2 preface.
    let mut srv = ntex::server::build().backlog(1024).bind(
        "grpc",
        "0.0.0.0:8080",
        ntex::SharedCfg::default(),
        async |_| server::GrpcServer::new(BenchmarkServer),
    )?;

    // The harness mounts /certs only for the TLS profile, so a missing pair
    // leaves the TLS listener down instead of aborting startup.
    let cert = std::env::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".into());
    let key = std::env::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".into());
    let (cert, key) = (Path::new(&cert), Path::new(&key));
    if cert.exists() && key.exists() {
        let tls = load_tls_config(cert, key)?;
        srv = srv.bind(
            "grpc-tls",
            "0.0.0.0:8443",
            ntex::SharedCfg::default(),
            async move |_| http::rustls(tls.clone(), &[], server::GrpcServer::new(BenchmarkServer)),
        )?;
    }

    srv.run().await
}
