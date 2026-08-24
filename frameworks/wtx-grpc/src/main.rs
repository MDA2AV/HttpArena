pub mod grpc_bindings;

use grpc_bindings::benchmark::{SumReply, SumRequest};
use wtx::{
  codec::format::QuickProtobuf,
  grpc::{GrpcManager, GrpcMiddleware},
  http::{
    HttpRecvParams,
    StatusCode,
    http2_server_framework::{Http2ServerFramework, HttpRouter, State, VerbatimParams, post},
  },
  tls::TlsConfig,
};

fn main() -> wtx::Result<()> {
  let router = HttpRouter::new(
    wtx::paths!(("/benchmark.BenchmarkService/GetSum", post(endpoint_grpc_unary))),
    GrpcMiddleware,
  )?;
  Http2ServerFramework::tokio(TlsConfig::plaintext())?
    .set_data(GrpcManager::from_drsr(QuickProtobuf))
    .set_http_recv_params(HttpRecvParams::with_permissive_params())
    .run_in_threads("0.0.0.0:8080", router)
}

// Returns VerbatimParams rather than (). ResFinalizer for () calls req.clear()
// after the handler runs, which erased the reply just serialized into the
// request buffer: the server answered 200 with grpc-status 0 and an empty
// body. VerbatimParams carries the status and leaves the body alone.
async fn endpoint_grpc_unary(
  state: State<'_, GrpcManager<QuickProtobuf>>,
) -> wtx::Result<VerbatimParams> {
  let sr = state.data.des_from_req_bytes::<SumRequest>(&mut state.req.msg_data.body.as_slice())?;
  state.req.clear();
  let result = sr.a.wrapping_add(sr.b);
  state.data.ser_to_res_bytes(&mut state.req.msg_data.body, SumReply { result })?;
  Ok(VerbatimParams(StatusCode::Ok))
}
