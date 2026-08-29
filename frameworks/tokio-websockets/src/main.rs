use core::net::SocketAddr;
use futures_util::{SinkExt, StreamExt};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::TcpListener;
use tokio::net::TcpStream;
use tokio_websockets::{Config, Limits, ServerBuilder};

const ADDR: &str = "0.0.0.0:8080";

fn main() {
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);

    let mut handles = Vec::with_capacity(threads);
    for _ in 0..threads {
        handles.push(std::thread::spawn(|| {
            tokio::runtime::Builder::new_current_thread()
                .enable_io()
                .build()
                .unwrap()
                .block_on(serve());
        }));
    }
    for h in handles {
        let _ = h.join();
    }
}

async fn serve() {
    let listener = bind_reuseport();
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(handle(stream));
            }
            Err(_) => continue,
        }
    }
}

fn bind_reuseport() -> TcpListener {
    let addr: SocketAddr = ADDR.parse().unwrap();
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).unwrap();
    socket.set_reuse_address(true).unwrap();
    socket.set_reuse_port(true).unwrap();
    socket.set_nonblocking(true).unwrap();
    socket.bind(&addr.into()).unwrap();
    socket.listen(1024).unwrap();
    TcpListener::from_std(socket.into()).unwrap()
}

async fn handle(stream: TcpStream) {
    let rslt = ServerBuilder::new()
        .config(Config::default().frame_size(usize::MAX))
        .limits(Limits::unlimited())
        .accept(stream)
        .await;
    let Ok((_request, mut ws_stream)) = rslt else {
      return;
    };
    while let Some(Ok(msg)) = ws_stream.next().await {
        if msg.is_text() || msg.is_binary() {
            ws_stream.send(msg).await.unwrap();
        }
    }
}
