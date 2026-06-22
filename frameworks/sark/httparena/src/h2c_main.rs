use std::io;

use dope::launcher::{Ctx, Launcher};
use httparena_sark::boot::Boot;
use httparena_sark::h2bench::BenchHandler;
use sark_h2::server::{Cfg, serve};

fn main() -> io::Result<()> {
    let boot = Boot::from_env(8082);
    let cfg = Cfg {
        bind: boot.bind,
        max_conn: boot.max_conn,
        backlog: 4096,
    };
    Launcher::new(boot.cpus).run(|ctx: Ctx| serve(BenchHandler::new(), cfg.clone(), ctx, None))
}
