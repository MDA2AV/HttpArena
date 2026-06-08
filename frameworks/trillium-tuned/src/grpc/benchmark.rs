use std::sync::Arc;
use trillium::{Conn, Handler, Method, Upgrade};
use trillium_grpc::{
    BidiConn, BidiResponder, GrpcServerConn, Prost, Server, ServiceClient, Status,
    Stream, StreamingConn, UnaryConn, prepare_grpc_conn,
};
#[derive(Clone, Copy, PartialEq, Eq, Hash, ::trillium_grpc::prost::Message)]
#[prost(prost_path = "::trillium_grpc::prost")]
pub struct SumRequest {
    #[prost(int32, tag = "1")]
    pub a: i32,
    #[prost(int32, tag = "2")]
    pub b: i32,
}
#[derive(Clone, Copy, PartialEq, Eq, Hash, ::trillium_grpc::prost::Message)]
#[prost(prost_path = "::trillium_grpc::prost")]
pub struct StreamRequest {
    #[prost(int32, tag = "1")]
    pub a: i32,
    #[prost(int32, tag = "2")]
    pub b: i32,
    #[prost(int32, tag = "3")]
    pub count: i32,
}
#[derive(Clone, Copy, PartialEq, Eq, Hash, ::trillium_grpc::prost::Message)]
#[prost(prost_path = "::trillium_grpc::prost")]
pub struct SumReply {
    #[prost(int32, tag = "1")]
    pub result: i32,
}
pub trait BenchmarkService: Send + Sync + 'static {
    fn get_sum(
        &self,
        conn: &mut GrpcServerConn,
        request: SumRequest,
    ) -> impl Future<Output = Result<SumReply, Status>> + Send;
    fn stream_sum(
        &self,
        conn: &mut GrpcServerConn,
        request: StreamRequest,
    ) -> impl Future<
        Output = Result<
            impl Stream<Item = Result<SumReply, Status>> + Send + use<Self>,
            Status,
        >,
    > + Send;
    fn collect_sum(
        &self,
        conn: &mut GrpcServerConn,
    ) -> impl Future<Output = Result<SumReply, Status>> + Send;
    fn echo_sum(
        &self,
        conn: &mut GrpcServerConn,
    ) -> impl Future<
        Output = Result<impl BidiResponder<SumRequest, SumReply> + use<Self>, Status>,
    > + Send;
}
pub struct BenchmarkServiceServer<T>(Arc<T>);
impl<T> BenchmarkServiceServer<T> {
    pub fn new(inner: T) -> Self {
        Self(Arc::new(inner))
    }
}
#[allow(clippy::enum_variant_names)]
#[derive(Debug, Clone, Copy)]
enum BenchmarkServiceDispatch {
    GetSum,
    StreamSum,
    CollectSum,
    EchoSum,
}
impl<T: BenchmarkService> Handler for BenchmarkServiceServer<T> {
    async fn run(&self, conn: Conn) -> Conn {
        const PREFIX: &str = "/benchmark.BenchmarkService";
        let Some(method) = conn.path().strip_prefix(PREFIX) else {
            return conn;
        };
        if conn.method() != Method::Post {
            return conn;
        }
        let dispatch = match method {
            "/GetSum" => BenchmarkServiceDispatch::GetSum,
            "/StreamSum" => BenchmarkServiceDispatch::StreamSum,
            "/CollectSum" => BenchmarkServiceDispatch::CollectSum,
            "/EchoSum" => BenchmarkServiceDispatch::EchoSum,
            _ => return conn,
        };
        let conn = match prepare_grpc_conn(conn, "proto") {
            Ok(c) => c,
            Err(c) => return c,
        };
        let inner = Arc::clone(&self.0);
        match dispatch {
            BenchmarkServiceDispatch::GetSum => {
                Prost::unary(conn, async move |grpc, req| inner.get_sum(grpc, req).await)
                    .await
            }
            BenchmarkServiceDispatch::StreamSum => {
                Prost::server_streaming(
                        conn,
                        async move |grpc, req| inner.stream_sum(grpc, req).await,
                    )
                    .await
            }
            BenchmarkServiceDispatch::CollectSum => {
                Prost::client_streaming(
                        conn,
                        async move |grpc| inner.collect_sum(grpc).await,
                    )
                    .await
            }
            BenchmarkServiceDispatch::EchoSum => {
                Prost::bidi::<
                    SumRequest,
                    SumReply,
                    _,
                >(conn, async move |grpc| inner.echo_sum(grpc).await)
                    .await
            }
        }
    }
    fn has_upgrade(&self, upgrade: &Upgrade) -> bool {
        trillium_grpc::has_bidi_upgrade(upgrade)
    }
    async fn upgrade(&self, upgrade: Upgrade) {
        trillium_grpc::drive_bidi_upgrade(upgrade).await;
    }
}
pub struct BenchmarkServiceClient(::trillium_grpc::trillium_client::Client);
impl From<::trillium_grpc::trillium_client::Client> for BenchmarkServiceClient {
    fn from(client: ::trillium_grpc::trillium_client::Client) -> Self {
        Self(trillium_grpc::with_service_prefix(client, "benchmark.BenchmarkService"))
    }
}
impl ServiceClient for BenchmarkServiceClient {
    fn client(&self) -> &::trillium_grpc::trillium_client::Client {
        &self.0
    }
    fn client_mut(&mut self) -> &mut ::trillium_grpc::trillium_client::Client {
        &mut self.0
    }
}
impl BenchmarkServiceClient {
    pub fn get_sum(&self, request: SumRequest) -> UnaryConn<SumRequest, SumReply> {
        UnaryConn::unary::<Prost>(&self.0, "GetSum", request)
    }
    pub fn stream_sum(
        &self,
        request: StreamRequest,
    ) -> StreamingConn<StreamRequest, SumReply> {
        StreamingConn::server_streaming::<Prost>(&self.0, "StreamSum", request)
    }
    pub fn collect_sum(
        &self,
        requests: impl Stream<Item = SumRequest> + Send + 'static,
    ) -> UnaryConn<SumRequest, SumReply> {
        UnaryConn::client_streaming::<Prost>(&self.0, "CollectSum", requests)
    }
    pub fn echo_sum(&self) -> BidiConn<SumRequest, SumReply> {
        BidiConn::bidi::<Prost>(&self.0, "EchoSum")
    }
}
