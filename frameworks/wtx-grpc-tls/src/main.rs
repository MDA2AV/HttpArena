pub mod grpc_bindings;

use grpc_bindings::benchmark::{StreamRequest, SumReply, SumRequest};
use tokio::net::tcp::OwnedWriteHalf;
use wtx::{
  codec::format::QuickProtobuf,
  grpc::{GrpcManager, GrpcMiddleware},
  http::{
    HttpRecvParams, ManualStream,
    http2_server_framework::{Http2ServerFramework, HttpRouter, State, post},
  },
  http2::{Http2RecvStatus, ServerStream},
  misc::SecretContext,
  rng::{ChaCha20, CryptoSeedableRng},
  tls::{TlsConfig, TlsModeVerified},
};

fn main() -> wtx::Result<()> {
  let cert_path = wtx::misc::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
  let key_path = wtx::misc::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
  let cert_file = std::fs::read_to_string(&cert_path)?.into_bytes();
  let mut key_file = std::fs::read_to_string(&key_path)?.into_bytes();
  let mut rng = ChaCha20::from_std_random()?;
  let secret_context = SecretContext::new(&mut rng)?;
  let tls_config = TlsConfig::from_keys_pem(&cert_file, &mut rng, (secret_context, &mut key_file))?;
  let router = HttpRouter::new(
    wtx::paths!(
      ("/benchmark.BenchmarkService/GetSum", post(endpoint_grpc_unary)),
      ("/benchmark.BenchmarkService/StreamSum", post(endpoint_grpc_stream))
    ),
    GrpcMiddleware,
  )?;
  Http2ServerFramework::tokio(tls_config)?
    .set_data(GrpcManager::from_drsr(QuickProtobuf))
    .set_http_recv_params(HttpRecvParams::with_permissive_params())
    .run_in_threads("0.0.0.0:8443", router)
}

async fn endpoint_grpc_unary(state: State<'_, GrpcManager<QuickProtobuf>>) -> wtx::Result<()> {
  let sr = state.data.des_from_req_bytes::<SumRequest>(state.req.msg_data.body.as_slice())?;
  state.req.clear();
  let result = sr.a.wrapping_add(sr.b);
  state.data.ser_to_res_bytes(&mut state.req.msg_data.body, SumReply { result })?;
  Ok(())
}

async fn endpoint_grpc_stream(
  mut ms: ManualStream<GrpcManager<QuickProtobuf>, ServerStream<OwnedWriteHalf, TlsModeVerified>>,
) -> wtx::Result<()> {
  let mut common = ms.stream.common();
  let Http2RecvStatus::Eos(mut bytes) = common.recv_data(|_| Ok(())).await? else {
    panic!();
  };
  let sr = ms.data.des_from_req_bytes::<StreamRequest>(bytes.as_slice())?;
  bytes.clear();
  let result = sr.a.wrapping_add(sr.b);
  ms.data.ser_to_res_bytes(&mut bytes, SumReply { result })?;
  common.send_data_concurrent::<_, 5000>((0..sr.count).map(|_| &bytes[..])).await?;
  Ok(())
}
