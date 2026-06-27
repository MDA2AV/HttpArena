use std::io;

use dope::launcher::{Ctx, Launcher};
use httparena_sark::boot::Boot;
use httparena_sark::grpcbench::{BenchSvc, benchmark_service_routes};
use sark_grpc::server::{Cfg, Config, serve, serve_tls};

fn main() -> io::Result<()> {
    let tls_on = std::env::var("SARK_GRPC_TLS").ok().as_deref() == Some("1");
    let boot = Boot::from_env(if tls_on { 8443 } else { 8080 });
    let cfg = Cfg {
        bind: boot.bind,
        readiness: Some(std::net::SocketAddr::from(([0, 0, 0, 0], 8080))),
        max_conn: boot.max_conn,
        backlog: 4096,
        grpc: Config::default(),
    };
    if tls_on {
        let tls = httparena_sark::tls::config(vec![b"h2".to_vec()]);
        Launcher::new(boot.cpus).run(|ctx: Ctx| {
            serve_tls(
                benchmark_service_routes(BenchSvc),
                cfg.clone(),
                tls.clone(),
                ctx,
                None,
            )
        })
    } else {
        Launcher::new(boot.cpus)
            .run(|ctx: Ctx| serve(benchmark_service_routes(BenchSvc), cfg.clone(), ctx, None))
    }
}
