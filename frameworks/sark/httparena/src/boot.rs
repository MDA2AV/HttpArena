use std::borrow::Cow;
use std::cell::Cell;
use std::env::{self, VarError};
use std::io;
use std::net::{AddrParseError, SocketAddr};
use std::num::{NonZero, ParseIntError};
use std::path::PathBuf;
use std::str::Utf8Error;

use cartel_redis::client::settings::init;
use percent_encoding::percent_decode_str;
use url::{SyntaxViolation, Url};

#[derive(Clone)]
pub struct Boot {
    pub tcp_bind: [SocketAddr; 4],
    pub h3_bind: SocketAddr,
    pub cpu_count: Option<NonZero<usize>>,
    pub max_connections: Option<NonZero<usize>>,
    pub database_connections: NonZero<usize>,
    pub h1_only: bool,
    pub dataset: PathBuf,
    pub static_root: PathBuf,
    pub certificate: PathBuf,
    pub private_key: PathBuf,
    pub database_url: Option<String>,
    pub redis_url: Option<String>,
}

#[derive(Debug)]
pub enum Error {
    Environment {
        name: &'static str,
        cause: VarError,
    },
    Address {
        name: &'static str,
        cause: AddrParseError,
    },
    Number {
        name: &'static str,
        cause: ParseIntError,
    },
    Boolean {
        name: &'static str,
        value: String,
    },
}

#[derive(Debug)]
pub enum UrlError {
    Parse(url::ParseError),
    Syntax(SyntaxViolation),
    Scheme(String),
    MissingHost,
    MissingUser,
    DatabasePath,
    Fragment,
    Option(String),
    Encoding {
        field: &'static str,
        cause: Utf8Error,
    },
    Database(ParseIntError),
    ZeroPort,
    Resolve(io::Error),
    NoAddress,
    Postgres(cartel_pg::ConfigError),
    Redis(init::Error),
    Allocation(o3::alloc::Error),
}

impl Boot {
    pub fn from_env() -> Result<Self, Error> {
        const DATABASE_CONNECTIONS: NonZero<usize> = NonZero::<usize>::MIN.saturating_add(255);
        Ok(Self {
            tcp_bind: [
                address("SARK_HTTPARENA_BIND", 8080)?,
                address("SARK_HTTPARENA_TLS_BIND", 8081)?,
                address("SARK_HTTPARENA_H2C_BIND", 8082)?,
                address("SARK_HTTPARENA_H2_BIND", 8443)?,
            ],
            h3_bind: address("SARK_HTTPARENA_H3_BIND", 8443)?,
            cpu_count: number("SARK_HTTPARENA_CPU_COUNT")?,
            max_connections: number("SARK_HTTPARENA_MAX_CONN")?,
            database_connections: number("DATABASE_MAX_CONN")?.unwrap_or(DATABASE_CONNECTIONS),
            h1_only: boolean("SARK_HTTPARENA_H1_ONLY")?,
            dataset: path("SARK_HTTPARENA_DATASET", "/data/dataset.json"),
            static_root: env::var_os("STATIC_ROOT")
                .or_else(|| env::var_os("STATIC_DIR"))
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/data/static")),
            certificate: path("SARK_HTTPARENA_CERT", "/certs/server.crt"),
            private_key: path("SARK_HTTPARENA_KEY", "/certs/server.key"),
            database_url: value("DATABASE_URL")?,
            redis_url: value("REDIS_URL")?,
        })
    }

    pub fn postgres(&self) -> Result<(Option<SocketAddr>, cartel_pg::Config), UrlError> {
        let Some(value) = self.database_url.as_deref() else {
            let config = cartel_pg::Config::new(
                String::from("bench"),
                String::from("bench"),
                String::from("benchmark"),
            )
            .map_err(UrlError::Postgres)?;
            return Ok((None, config));
        };
        let url = parse_url(value)?;
        if !matches!(url.scheme(), "postgres" | "postgresql") {
            return Err(UrlError::Scheme(url.scheme().to_owned()));
        }
        for (name, value) in url.query_pairs() {
            if name != "sslmode" || value != "disable" {
                return Err(UrlError::Option(name.into_owned()));
            }
        }
        let user = decode(url.username(), "user")?;
        if user.is_empty() {
            return Err(UrlError::MissingUser);
        }
        let password = decode(url.password().unwrap_or_default(), "password")?;
        let path = database_path(value)?;
        let database = if path.is_empty() {
            user.clone()
        } else {
            decode(path, "database")?
        };
        let config =
            cartel_pg::Config::new(user, password, database).map_err(UrlError::Postgres)?;
        let address = resolve(&url, NonZero::<u16>::MIN.saturating_add(5431))?;
        Ok((Some(address), config))
    }

    pub fn redis(&self) -> Result<(Option<SocketAddr>, init::Plan), UrlError> {
        let Some(value) = self.redis_url.as_deref() else {
            return Ok((None, init::Plan::new()));
        };
        let url = parse_url(value)?;
        if url.scheme() != "redis" {
            return Err(UrlError::Scheme(url.scheme().to_owned()));
        }
        if let Some((name, _)) = url.query_pairs().next() {
            return Err(UrlError::Option(name.into_owned()));
        }
        let username = Cow::<[u8]>::from(percent_decode_str(url.username()));
        let mut plan = init::Plan::new();
        match (username.is_empty(), url.password()) {
            (true, None) => {}
            (true, Some(password)) => {
                plan = plan
                    .password(Cow::<[u8]>::from(percent_decode_str(password)))
                    .map_err(UrlError::Allocation)?;
            }
            (false, password) => {
                plan = plan
                    .user(
                        username,
                        Cow::<[u8]>::from(percent_decode_str(password.unwrap_or_default())),
                    )
                    .map_err(UrlError::Redis)?;
            }
        }
        let path = database_path(value)?;
        if !path.is_empty() {
            let database = decode(path, "database")?
                .parse()
                .map_err(UrlError::Database)?;
            plan = plan.select(database);
        }
        let address = resolve(&url, NonZero::<u16>::MIN.saturating_add(6378))?;
        Ok((Some(address), plan))
    }
}

fn parse_url(value: &str) -> Result<Url, UrlError> {
    let violation = Cell::new(None);
    let record = |cause| {
        if cause != SyntaxViolation::EmbeddedCredentials && violation.get().is_none() {
            violation.set(Some(cause));
        }
    };
    let url = Url::options()
        .syntax_violation_callback(Some(&record))
        .parse(value)
        .map_err(UrlError::Parse)?;
    if let Some(cause) = violation.get() {
        return Err(UrlError::Syntax(cause));
    }
    if url.host().is_none() {
        return Err(UrlError::MissingHost);
    }
    if url.fragment().is_some() {
        return Err(UrlError::Fragment);
    }
    if url.port() == Some(0) {
        return Err(UrlError::ZeroPort);
    }
    Ok(url)
}

fn database_path(value: &str) -> Result<&str, UrlError> {
    let (_, target) = value.split_once("://").ok_or(UrlError::DatabasePath)?;
    let target = target.split(['?', '#']).next().unwrap_or_default();
    let path = target.split_once('/').map_or("", |(_, path)| path);
    if path.contains('/') {
        return Err(UrlError::DatabasePath);
    }
    Ok(path)
}

fn decode(value: &str, field: &'static str) -> Result<String, UrlError> {
    percent_decode_str(value)
        .decode_utf8()
        .map(|value| value.into_owned())
        .map_err(|cause| UrlError::Encoding { field, cause })
}

fn resolve(url: &Url, default: NonZero<u16>) -> Result<SocketAddr, UrlError> {
    url.socket_addrs(|| Some(default.get()))
        .map_err(UrlError::Resolve)?
        .into_iter()
        .next()
        .ok_or(UrlError::NoAddress)
}

fn value(name: &'static str) -> Result<Option<String>, Error> {
    match env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(VarError::NotPresent) => Ok(None),
        Err(cause) => Err(Error::Environment { name, cause }),
    }
}

fn path(name: &'static str, default: &str) -> PathBuf {
    env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default))
}

fn address(name: &'static str, port: u16) -> Result<SocketAddr, Error> {
    match value(name)? {
        Some(value) => value
            .parse()
            .map_err(|cause| Error::Address { name, cause }),
        None => Ok(SocketAddr::from(([0, 0, 0, 0], port))),
    }
}

fn number(name: &'static str) -> Result<Option<NonZero<usize>>, Error> {
    value(name)?
        .map(|value| value.parse().map_err(|cause| Error::Number { name, cause }))
        .transpose()
}

fn boolean(name: &'static str) -> Result<bool, Error> {
    match value(name)? {
        None => Ok(false),
        Some(value) if value == "0" => Ok(false),
        Some(value) if value == "1" => Ok(true),
        Some(value) => Err(Error::Boolean { name, value }),
    }
}
