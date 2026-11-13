use std::{net::SocketAddr, num::NonZero, path::PathBuf};

use httparena_sark::boot::Boot;

pub fn settings(database_url: Option<&str>, redis_url: Option<&str>) -> Boot {
    let bind = SocketAddr::from(([127, 0, 0, 1], 0));
    Boot {
        tcp_bind: [bind; 4],
        h3_bind: bind,
        cpu_count: Some(NonZero::<usize>::MIN),
        max_connections: Some(NonZero::<usize>::MIN),
        database_connections: NonZero::<usize>::MIN,
        h1_only: true,
        dataset: PathBuf::new(),
        static_root: PathBuf::new(),
        certificate: PathBuf::new(),
        private_key: PathBuf::new(),
        database_url: database_url.map(str::to_owned),
        redis_url: redis_url.map(str::to_owned),
    }
}
