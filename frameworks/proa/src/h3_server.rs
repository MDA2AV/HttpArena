use std::{net::SocketAddr, sync::Arc};

use axum::{
    body::Bytes,
    http::{
        HeaderValue, Response, StatusCode,
        header::{ACCEPT_ENCODING, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, VARY},
    },
};
use quinn::{
    Endpoint, EndpointConfig, ServerConfig as QuinnServerConfig, TransportConfig,
    crypto::rustls::QuicServerConfig,
};
use rustls::ServerConfig;
use socket2::{Domain, Protocol, Socket, Type};

use crate::{baseline_get_bytes, static_files::read_static};

const TEXT_PLAIN: HeaderValue = HeaderValue::from_static("text/plain");
const VARY_AE: HeaderValue = HeaderValue::from_static("Accept-Encoding");

pub fn build_quinn_config(tls: Arc<ServerConfig>) -> Option<QuinnServerConfig> {
    let quic_crypto = QuicServerConfig::try_from(tls).ok()?;
    let mut server_config = QuinnServerConfig::with_crypto(Arc::new(quic_crypto));
    let mut transport = TransportConfig::default();
    transport.max_concurrent_bidi_streams(256u32.into());
    transport.max_concurrent_uni_streams(32u32.into());
    transport.send_window(8 * 1024 * 1024);
    transport.receive_window((16 * 1024 * 1024u32).into());
    transport.stream_receive_window((2 * 1024 * 1024u32).into());
    transport.datagram_receive_buffer_size(None);
    server_config.transport_config(Arc::new(transport));
    Some(server_config)
}

pub fn reuseport_udp(addr: SocketAddr) -> std::io::Result<std::net::UdpSocket> {
    let sock = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    sock.set_reuse_address(true)?;
    #[cfg(unix)]
    sock.set_reuse_port(true)?;
    let _ = sock.set_recv_buffer_size(4 * 1024 * 1024);
    let _ = sock.set_send_buffer_size(4 * 1024 * 1024);
    sock.set_nonblocking(true)?;
    sock.bind(&addr.into())?;
    Ok(sock.into())
}

pub fn spawn_h3_worker(
    std_udp: std::net::UdpSocket,
    server_config: QuinnServerConfig,
) -> std::io::Result<()> {
    let endpoint = Endpoint::new(
        EndpointConfig::default(),
        Some(server_config),
        std_udp,
        Arc::new(quinn::TokioRuntime),
    )?;

    tokio::spawn(async move {
        while let Some(incoming) = endpoint.accept().await {
            tokio::spawn(async move {
                let Ok(conn) = incoming.await else {
                    return;
                };
                let Ok(mut h3_conn) =
                    h3::server::Connection::<_, Bytes>::new(h3_quinn::Connection::new(conn)).await
                else {
                    return;
                };
                while let Ok(Some(resolver)) = h3_conn.accept().await {
                    tokio::spawn(async move {
                        let Ok((req, mut stream)) = resolver.resolve_request().await else {
                            return;
                        };
                        // Drain the request receive stream to FIN so quinn's RecvStream::drop
                        // does not emit STOP_SENDING(0), which nghttp3/h2load treats as a stream error.
                        while let Ok(Some(_)) = stream.recv_data().await {}

                        let path = req.uri().path();
                        let (resp, body) = if path == "/baseline2" {
                            match baseline_get_bytes(req.uri()) {
                                Ok(bytes) => {
                                    let resp = Response::builder()
                                        .status(StatusCode::OK)
                                        .header(CONTENT_TYPE, TEXT_PLAIN)
                                        .header(CONTENT_LENGTH, bytes.len())
                                        .body(())
                                        .unwrap();
                                    (resp, bytes)
                                }
                                Err(status) => (
                                    Response::builder().status(status).body(()).unwrap(),
                                    Bytes::new(),
                                ),
                            }
                        } else if let Some(rel) = path.strip_prefix("/static/") {
                            let ae = req
                                .headers()
                                .get(ACCEPT_ENCODING)
                                .and_then(|v| v.to_str().ok());
                            match read_static(rel, ae) {
                                Some(file) => {
                                    let mut builder = Response::builder()
                                        .status(StatusCode::OK)
                                        .header(CONTENT_TYPE, file.content_type)
                                        .header(CONTENT_LENGTH, file.body.len());
                                    if let Some(enc) = file.content_encoding {
                                        builder = builder
                                            .header(CONTENT_ENCODING, enc)
                                            .header(VARY, VARY_AE);
                                    }
                                    (builder.body(()).unwrap(), file.body)
                                }
                                None => (
                                    Response::builder()
                                        .status(StatusCode::NOT_FOUND)
                                        .body(())
                                        .unwrap(),
                                    Bytes::new(),
                                ),
                            }
                        } else {
                            (
                                Response::builder()
                                    .status(StatusCode::NOT_FOUND)
                                    .body(())
                                    .unwrap(),
                                Bytes::new(),
                            )
                        };

                        if stream.send_response(resp).await.is_err() {
                            return;
                        }
                        if !body.is_empty() && stream.send_data(body).await.is_err() {
                            return;
                        }
                        let _ = stream.finish().await;
                    });
                }
            });
        }
    });

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use hyper::body::Buf;
    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use rustls::{ClientConfig, DigitallySignedStruct, Error as TlsError, SignatureScheme};

    #[derive(Debug)]
    struct AcceptAnyCert;

    impl ServerCertVerifier for AcceptAnyCert {
        fn verify_server_cert(
            &self,
            _end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, TlsError> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, TlsError> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self,
            _message: &[u8],
            _cert: &CertificateDer<'_>,
            _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, TlsError> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            rustls::crypto::aws_lc_rs::default_provider()
                .signature_verification_algorithms
                .supported_schemes()
        }
    }

    #[test]
    fn h3_serves_baseline2_over_quic() {
        let cert_path = std::env::var("TLS_CERT").unwrap_or_default();
        if cert_path.is_empty() {
            return;
        }
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async {
            let bundle = crate::load_tls_bundle().expect("tls bundle");
            let q_cfg = bundle.h3.expect("quinn config");
            let std_udp = reuseport_udp("127.0.0.1:0".parse().unwrap()).unwrap();
            let addr = std_udp.local_addr().unwrap();
            spawn_h3_worker(std_udp, q_cfg).unwrap();

            let mut tls_client = ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::aws_lc_rs::default_provider(),
            ))
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptAnyCert))
            .with_no_client_auth();
            tls_client.alpn_protocols = vec![b"h3".to_vec()];
            let client_cfg = quinn::ClientConfig::new(Arc::new(
                quinn::crypto::rustls::QuicClientConfig::try_from(tls_client).unwrap(),
            ));
            let mut client = Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
            client.set_default_client_config(client_cfg);
            let conn = client.connect(addr, "localhost").unwrap().await.unwrap();
            let (mut driver, mut send_req) =
                h3::client::new(h3_quinn::Connection::new(conn)).await.unwrap();
            let driver_task = tokio::spawn(async move {
                let _ = std::future::poll_fn(|cx| driver.poll_close(cx)).await;
            });

            // 1. GET /baseline2?a=13&b=42
            let req = axum::http::Request::builder()
                .uri("https://localhost/baseline2?a=13&b=42")
                .body(())
                .unwrap();
            let mut stream = send_req.send_request(req).await.unwrap();
            stream.finish().await.unwrap();
            let resp = stream.recv_response().await.unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
            assert_eq!(resp.headers().get(CONTENT_TYPE).unwrap(), "text/plain");
            let mut body = Vec::new();
            while let Some(chunk) = stream.recv_data().await.unwrap() {
                body.extend_from_slice(chunk.chunk());
            }
            assert_eq!(body, b"55");

            // 2. GET /static/reset.css (with br) and 404
            if std::env::var("STATIC_DIR").is_ok() {
                let req = axum::http::Request::builder()
                    .uri("https://localhost/static/reset.css")
                    .header(ACCEPT_ENCODING, "br;q=1, gzip;q=0.8")
                    .body(())
                    .unwrap();
                let mut stream = send_req.send_request(req).await.unwrap();
                stream.finish().await.unwrap();
                let resp = stream.recv_response().await.unwrap();
                assert_eq!(resp.status(), StatusCode::OK);
                assert_eq!(resp.headers().get(CONTENT_TYPE).unwrap(), "text/css");
                assert_eq!(resp.headers().get(CONTENT_ENCODING).unwrap(), "br");
                let mut body = Vec::new();
                while let Some(chunk) = stream.recv_data().await.unwrap() {
                    body.extend_from_slice(chunk.chunk());
                }
                assert_eq!(body, b"FAKE_BR_BYTES");
            }

            driver_task.abort();
        });
    }
}
