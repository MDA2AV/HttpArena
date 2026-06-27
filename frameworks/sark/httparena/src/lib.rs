pub mod boot;
pub mod cache;
pub mod dataset;
pub mod demux;
pub mod demux8080;
pub mod grpcbench;
pub mod h2bench;
pub mod json;
pub mod model;

pub mod tls {
    use shin::sig::SigningKey;

    const SEED: [u8; 32] = [
        0x42, 0x9a, 0x1d, 0x77, 0x0b, 0xe3, 0x55, 0x10, 0x2c, 0x84, 0xf1, 0x60, 0x39, 0xaa, 0xcd,
        0x18, 0x5e, 0x07, 0xb2, 0x6f, 0xc3, 0x91, 0x4d, 0x28, 0x70, 0xe9, 0x1a, 0x55, 0x8b, 0x3c,
        0xd0, 0x66,
    ];

    const PKCS8_PREFIX: [u8; 16] = [
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04,
        0x20,
    ];

    pub fn quic_cert() -> (Vec<Vec<u8>>, SigningKey) {
        let mut pkcs8 = Vec::with_capacity(48);
        pkcs8.extend_from_slice(&PKCS8_PREFIX);
        pkcs8.extend_from_slice(&SEED);
        let key_pair =
            rcgen::KeyPair::from_pkcs8_der_and_sign_algo(&pkcs8.into(), &rcgen::PKCS_ED25519)
                .expect("rcgen ed25519 key from seed");
        let params =
            rcgen::CertificateParams::new(vec!["localhost".to_string()]).expect("cert params");
        let cert = params.self_signed(&key_pair).expect("self-signed cert");
        let chain_der = vec![cert.der().to_vec()];
        let signing_key = SigningKey::from_seed(&SEED).expect("shin signing key");
        (chain_der, signing_key)
    }

    pub fn config(alpn_protocols: Vec<Vec<u8>>) -> shin::server::Config {
        let (chain_der, signing_key) = quic_cert();
        shin::server::Config {
            source: shin::server::CertSource::X509 {
                chain_der,
                signing_key,
            },
            transport_params: Vec::new(),
            alpn_protocols,
            ticket_secret: None,
            accept_early_data: false,
        }
    }
}
