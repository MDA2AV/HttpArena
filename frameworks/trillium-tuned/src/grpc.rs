//! gRPC `benchmark.BenchmarkService`, served over trillium-grpc.
//!
//! Mounts into the same handler tree as the HTTP endpoints — the server handler
//! matches its own `/benchmark.BenchmarkService/*` path prefix and passes every
//! other request through. Exercised by the `unary-grpc` (`GetSum`) and
//! `stream-grpc` (`StreamSum`) profiles over h2c on 8080 and h2-over-TLS on 8443;
//! `CollectSum` and `EchoSum` round out the service the proto defines.

use futures_lite::stream;
use trillium_grpc::{BidiResponder, Channel, GrpcServerConn, Status, Stream};

#[allow(dead_code)] // the generated client half is unused on the server
mod benchmark {
    include!("grpc/benchmark.rs");
}

pub use benchmark::BenchmarkServiceServer;
use benchmark::{BenchmarkService, StreamRequest, SumReply, SumRequest};

pub struct Benchmark;

impl BenchmarkService for Benchmark {
    async fn get_sum(
        &self,
        _conn: &mut GrpcServerConn,
        request: SumRequest,
    ) -> Result<SumReply, Status> {
        Ok(SumReply {
            result: request.a + request.b,
        })
    }

    async fn stream_sum(
        &self,
        _conn: &mut GrpcServerConn,
        request: StreamRequest,
    ) -> Result<impl Stream<Item = Result<SumReply, Status>> + Send + use<>, Status> {
        let result = request.a + request.b;
        let count = request.count.max(0) as usize;
        Ok(stream::iter(
            (0..count).map(move |_| Ok(SumReply { result })),
        ))
    }

    async fn collect_sum(&self, conn: &mut GrpcServerConn) -> Result<SumReply, Status> {
        let mut result = 0;
        let mut requests = conn.requests::<SumRequest>();
        while let Some(request) = requests.recv().await? {
            result += request.a + request.b;
        }
        Ok(SumReply { result })
    }

    async fn echo_sum(
        &self,
        _conn: &mut GrpcServerConn,
    ) -> Result<impl BidiResponder<SumRequest, SumReply> + use<>, Status> {
        Ok(EchoSum)
    }
}

struct EchoSum;

impl BidiResponder<SumRequest, SumReply> for EchoSum {
    async fn respond(self, mut channel: Channel<'_, SumRequest, SumReply>) -> Result<(), Status> {
        while let Some(request) = channel.recv().await.transpose()? {
            channel
                .send(SumReply {
                    result: request.a + request.b,
                })
                .await?;
        }
        Ok(())
    }
}
