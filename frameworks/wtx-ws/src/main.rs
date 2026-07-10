use tokio::net::TcpStream;
use wtx::{
  collections::Vector,
  executor::TokioExecutor,
  http::WebSocketServerFramework,
  misc::TcpParams,
  tls::{TlsConfig, TlsModePlainText},
  web_socket::{OpCode, WebSocket, WebSocketPayloadOrigin},
};

type LocalWebSocket = WebSocket<(), TcpStream, TlsModePlainText, false>;

fn main() -> wtx::Result<()> {
  WebSocketServerFramework::new(TokioExecutor::default(), TlsConfig::plaintext())?
    .set_tcp_params(TcpParams::default().tcp_nodelay(false))
    .run_in_threads("0.0.0.0:8080", (("/ws", ws),))
}

async fn ws(mut buffer: Vector<u8>, mut ws: LocalWebSocket) -> wtx::Result<()> {
  let (mut common, mut reader, mut writer) = ws.split_mut();
  loop {
    let origin = WebSocketPayloadOrigin::Adaptive;
    let Ok(mut frame) = reader.read_frame(&mut buffer, &mut common, origin).await else {
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
