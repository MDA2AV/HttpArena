pub mod grpc_bindings;

use wtx::{
  codec::format::QuickProtobuf,
  collection::Vector,
  grpc::{GrpcManager, GrpcMiddleware},
  http::{
    HttpRecvParams, MsgBufferString,
    server_framework::{Router, ServerFrameworkBuilder, State, post},
  },
};

fn main() {
  let threads = std::thread::available_parallelism().map(|el| el.get()).unwrap_or(1);
  let mut handlers = Vector::new();
  for _ in 0..threads {
    let handle = std::thread::spawn(|| {
      tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(serve())
    });
    handlers.push(handle).unwrap();
  }
  for handle in handlers {
    handle.join().unwrap();
  }
}

async fn endpoint_grpc_unary(
  state: State<'_, (), GrpcManager<QuickProtobuf>, MsgBufferString>,
) -> wtx::Result<()> {
  let sr: grpc_bindings::benchmark::SumRequest =
    state.stream_aux.des_from_req_bytes(&mut state.req.msg_data.body.as_slice())?;
  state.req.clear();
  let result = sr.a.wrapping_add(sr.b);
  state.stream_aux.ser_to_res_bytes(
    &mut state.req.msg_data.body,
    grpc_bindings::benchmark::SumReply { result },
  )?;
  Ok(())
}

async fn serve() {
  let router = Router::new(
    wtx::paths!(("/benchmark.BenchmarkService/GetSum", post(endpoint_grpc_unary))),
    GrpcMiddleware,
  )
  .unwrap();
  let _rslt = ServerFrameworkBuilder::new(HttpRecvParams::with_permissive_params(), router)
    .with_stream_aux(|_| Ok(QuickProtobuf))
    .tokio(
      "0.0.0.0:8080",
      |_error| {},
      |_| Ok(()),
      |_stream| Ok(()),
      |_error| {},
    )
    .await;
}
