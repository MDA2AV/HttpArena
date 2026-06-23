use std::io;

use dope::launcher::{Ctx, Launcher};
use httparena_sark::boot::Boot;
use httparena_sark::h2bench::BenchHandler;
use sark::fs::ServeDir;
use sark_h2::server::{Cfg, serve_tls};

fn main() -> io::Result<()> {
    let boot = Boot::from_env(8443);
    let cfg = Cfg {
        bind: boot.bind,
        max_conn: boot.max_conn,
        backlog: 4096,
    };
    let tls = httparena_sark::tls::config(vec![b"h2".to_vec()]);
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    let serve: &'static ServeDir = Box::leak(Box::new(
        ServeDir::new(&static_dir)
            .precompressed_br()
            .precompressed_gzip(),
    ));
    Launcher::new(boot.cpus).run(|ctx: Ctx| {
        serve_tls(
            BenchHandler::with_serve(serve),
            cfg.clone(),
            tls.clone(),
            ctx,
            None,
        )
    })
}
