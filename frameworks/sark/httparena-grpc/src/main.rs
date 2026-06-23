use std::io;

use dope::launcher::{Ctx, Launcher};
use httparena_sark::boot::Boot;
use sark_grpc::server::{Cfg, Config, serve, serve_tls};
use sark_grpc::{StreamingRequest, StreamingResponse, UnaryRequest, UnaryResponse};

include!(concat!(env!("OUT_DIR"), "/benchmark.rs"));

struct BenchSvc;

impl BenchmarkServiceService for BenchSvc {
    fn get_sum(&mut self, request: UnaryRequest<SumRequest>) -> UnaryResponse<SumReply> {
        UnaryResponse::new(SumReply {
            result: request.message.a.wrapping_add(request.message.b),
        })
    }

    fn stream_sum(
        &mut self,
        request: StreamingRequest<StreamRequest>,
    ) -> StreamingResponse<SumReply> {
        let mut replies = Vec::new();
        for msg in &request.messages {
            let sum = msg.a.wrapping_add(msg.b);
            let count = msg.count.max(0) as usize;
            for _ in 0..count {
                replies.push(SumReply { result: sum });
            }
        }
        StreamingResponse::new(replies)
    }
}

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
