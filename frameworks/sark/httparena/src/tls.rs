use std::path::Path;

use dope_tls::{config::Ext as _, rustls};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem, pem::PemObject as _};

#[derive(Debug)]
pub enum Error {
    Certificates(pem::Error),
    EmptyCertificates,
    PrivateKey(pem::Error),
    MissingPrivateKey,
    MultiplePrivateKeys,
    Config(dope_tls::Error),
    Identity(rustls::Error),
}

pub fn config(certificate: &Path, private_key: &Path) -> Result<rustls::ServerConfig, Error> {
    let certificates = CertificateDer::pem_file_iter(certificate)
        .map_err(Error::Certificates)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(Error::Certificates)?;
    if certificates.is_empty() {
        return Err(Error::EmptyCertificates);
    }
    let mut keys = PrivateKeyDer::pem_file_iter(private_key).map_err(Error::PrivateKey)?;
    let key = keys
        .next()
        .transpose()
        .map_err(Error::PrivateKey)?
        .ok_or(Error::MissingPrivateKey)?;
    if keys
        .next()
        .transpose()
        .map_err(Error::PrivateKey)?
        .is_some()
    {
        return Err(Error::MultiplePrivateKeys);
    }
    drop(keys);
    rustls::ServerConfig::try_tls13()
        .map_err(Error::Config)?
        .with_no_client_auth()
        .with_single_cert(certificates, key)
        .map_err(Error::Identity)
}
