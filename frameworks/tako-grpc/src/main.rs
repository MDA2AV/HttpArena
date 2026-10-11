use prost::Message;
use tako::grpc::{GrpcRequest, GrpcResponse};
use tako::router::Router;
use tako::types::BoxError;
use tako::{Server, TlsCert};
use tokio::net::TcpListener;

const CERT: &str = "/certs/server.crt";
const KEY: &str = "/certs/server.key";

#[derive(Clone, PartialEq, Message)]
struct SumRequest {
    #[prost(int32, tag = "1")]
    a: i32,
    #[prost(int32, tag = "2")]
    b: i32,
}

#[derive(Clone, PartialEq, Message)]
struct SumReply {
    #[prost(int32, tag = "1")]
    result: i32,
}

async fn get_sum(req: GrpcRequest<SumRequest>) -> GrpcResponse<SumReply> {
    GrpcResponse::ok(SumReply {
        result: req.message.a.wrapping_add(req.message.b),
    })
}

fn router() -> Router {
    let mut router = Router::new();
    router.post("/benchmark.BenchmarkService/GetSum", get_sum);
    router
}

#[tokio::main]
async fn main() -> Result<(), BoxError> {
    let server = Server::builder().tls(TlsCert::pem_paths(CERT, KEY)).build();
    let h2c = TcpListener::bind("0.0.0.0:8080").await?;
    let mut handles = vec![server.try_spawn_h2c(h2c, router())?];
    if std::path::Path::new(CERT).exists() && std::path::Path::new(KEY).exists() {
        let h2 = TcpListener::bind("0.0.0.0:8443").await?;
        handles.push(server.try_spawn_tls(h2, router())?);
    }
    for handle in handles {
        handle.result().await?;
    }
    Ok(())
}
