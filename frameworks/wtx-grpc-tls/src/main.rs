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
  tls::{TlsConfig, TlsModeVerified},
};

fn main() -> wtx::Result<()> {
  let cert_path = wtx::misc::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
  let key_path = wtx::misc::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
  let cert_file = std::fs::read_to_string(&cert_path)?.into_bytes();
  let key_file = std::fs::read_to_string(&key_path)?.into_bytes();
  let tls_config = TlsConfig::from_keys_pem(TlsModeVerified::new(), &cert_file, &key_file)?;
  let router = HttpRouter::new(
    wtx::paths!(("/benchmark.BenchmarkService/GetSum", post(endpoint_grpc_unary))),
    GrpcMiddleware,
  )?;
  Http2ServerFramework::tokio(tls_config)?
    .set_data(GrpcManager::from_drsr(QuickProtobuf))
    .set_error_cb(|el| eprintln!("{el}"))
    .set_http_recv_params(HttpRecvParams::with_permissive_params())
    .run_in_threads("0.0.0.0:8443", router)
}

// Same fix as the plaintext entry: ResFinalizer for () clears the request
// buffer after the handler runs, which erased the serialized reply.
async fn endpoint_grpc_unary(
  state: State<'_, GrpcManager<QuickProtobuf>>,
) -> wtx::Result<VerbatimParams> {
  let sr = state.data.des_from_req_bytes::<SumRequest>(&mut state.req.msg_data.body.as_slice())?;
  state.req.clear();
  let result = sr.a.wrapping_add(sr.b);
  state.data.ser_to_res_bytes(&mut state.req.msg_data.body, SumReply { result })?;
  Ok(VerbatimParams(StatusCode::Ok))
}
