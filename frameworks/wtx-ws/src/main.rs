use tokio::net::TcpStream;
use wtx::{
  collection::Vector,
  http::OptionedServer,
  rng::Xorshift64,
  web_socket::{OpCode, WebSocket, WebSocketBuffer, WebSocketPayloadOrigin},
};

fn main() {
  let threads = std::thread::available_parallelism().map(|el| el.get()).unwrap_or(1);
  let mut handlers = Vector::new();
  for _ in 0..threads {
    let handle = std::thread::spawn(move || {
      tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
        let cb = (|| Ok(()), |_, stream| async move { Ok(stream) });
        let _el = OptionedServer::web_socket_tokio("0.0.0.0:8080", || {}, |_| {}, handle, cb).await;
      });
    });
    handlers.push(handle).unwrap();
  }
  for handle in handlers {
    handle.join().unwrap();
  }
}

async fn handle(
  path: String,
  mut ws: WebSocket<(), Xorshift64, TcpStream, WebSocketBuffer, false>,
) -> wtx::Result<()> {
  if path != "/ws" {
    return Ok(());
  }
  let (mut common, mut reader, mut writer) = ws.split_mut();
  let payload_origin = WebSocketPayloadOrigin::Adaptive;
  let mut buffer = path.into_bytes().into();
  loop {
    let Ok(mut frame) = reader.read_frame(&mut buffer, &mut common, payload_origin).await else {
      return Ok(());
    };
    match frame.op_code() {
      OpCode::Binary | OpCode::Text => {
        if writer.write_frame(&mut common, &mut frame).await.is_err() {
          return Ok(());
        }
      }
      OpCode::Close => return Ok(()),
      _ => {}
    }
  }
}
