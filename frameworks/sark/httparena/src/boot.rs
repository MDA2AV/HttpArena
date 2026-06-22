use std::net::SocketAddr;

use dope::launcher::Launcher;

pub struct Boot {
    pub bind: SocketAddr,
    pub cpus: Vec<u16>,
    pub max_conn: usize,
}

impl Boot {
    pub fn from_env(default_port: u16) -> Self {
        let bind = std::env::var("SARK_HTTPARENA_BIND")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or_else(|| SocketAddr::from(([0, 0, 0, 0], default_port)));
        let allowed = Launcher::allowed_cpus();
        let count = std::env::var("SARK_HTTPARENA_CPU_COUNT")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|&n| n > 0)
            .unwrap_or(allowed.len());
        let core = std::env::var("SARK_HTTPARENA_CPU_CORE")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        let max_conn = std::env::var("SARK_HTTPARENA_MAX_CONN")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(16384);
        let cpus: Vec<u16> = allowed.into_iter().skip(core).take(count).collect();
        let cpus = if cpus.is_empty() { vec![0] } else { cpus };
        Self {
            bind,
            cpus,
            max_conn,
        }
    }
}
