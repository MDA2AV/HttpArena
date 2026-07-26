use std::io;

use dope::launcher::{Ctx, Launcher};
use httparena_sark::boot::Boot;
use sark_ws::server::{Cfg, Message, Response, serve};

type EchoHandler = for<'a, 'b, 'c> fn(Message<'a>, &'b mut Response<'c>);

fn echo(msg: Message<'_>, response: &mut Response<'_>) {
    match msg {
        Message::Text(s) => {
            response.text(s);
        }
        Message::Binary(b) => {
            response.binary(b);
        }
    }
}

fn main() -> io::Result<()> {
    let boot = Boot::from_env(8080);
    let cfg = Cfg {
        bind: boot.bind,
        max_conn: boot.max_conn,
        backlog: 4096,
        path: "/ws",
        max_frame_payload: 16 * 1024 * 1024,
    };
    Launcher::new(boot.cpus).run(|ctx: Ctx| serve(echo as EchoHandler, cfg.clone(), ctx, None))
}
