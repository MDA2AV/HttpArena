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
        let total_max_conn = std::env::var("SARK_HTTPARENA_MAX_CONN")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(16384usize);
        let cpus: Vec<u16> = allowed.into_iter().take(count).collect();
        let cpus = if cpus.is_empty() { vec![0] } else { cpus };
        let max_conn = total_max_conn
            .div_ceil(cpus.len())
            .saturating_mul(2)
            .clamp(1024, total_max_conn.max(1024));
        Self {
            bind,
            cpus,
            max_conn,
        }
    }
}
