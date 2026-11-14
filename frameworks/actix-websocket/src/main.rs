use actix_web::{web, App, HttpServer, HttpRequest, HttpResponse};
use actix_ws::{AggregatedMessage, CloseCode, CloseReason, ProtocolError};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

// The echo, and the close handshake around it (RFC 6455 5.5): a Close is
// answered with a Close carrying the client's code, a Ping with a Pong, and a
// connection that breaks the protocol is failed with the code that says why
// rather than dropped. Fragmented messages are reassembled, so each goes back
// as the message it was.
async fn ws_handler(req: HttpRequest, body: web::Payload) -> actix_web::Result<HttpResponse> {
    let (response, mut session, msg_stream) = actix_ws::handle(&req, body)?;
    let mut msg_stream = msg_stream.aggregate_continuations();
    actix_web::rt::spawn(async move {
        let reason = loop {
            let sent = match msg_stream.recv().await {
                Some(Ok(AggregatedMessage::Text(text))) => session.text(text).await,
                Some(Ok(AggregatedMessage::Binary(bin))) => session.binary(bin).await,
                Some(Ok(AggregatedMessage::Ping(bytes))) => session.pong(&bytes).await,
                Some(Ok(AggregatedMessage::Pong(_))) => Ok(()),
                Some(Ok(AggregatedMessage::Close(reason))) => break reason,
                Some(Err(err)) => break Some(CloseReason::from(close_code(&err))),
                // the client went away: no one is left to tell
                None => return,
            };
            if sent.is_err() {
                return;
            }
        };
        let _ = session.close(reason).await;
    });
    Ok(response)
}

// Invalid UTF-8 in a text message is 1007, a frame over the size limit 1009,
// anything else the protocol forbids 1002.
fn close_code(err: &ProtocolError) -> CloseCode {
    match err {
        ProtocolError::Io(e) if e.kind() == std::io::ErrorKind::InvalidData => CloseCode::Invalid,
        ProtocolError::Overflow => CloseCode::Size,
        _ => CloseCode::Protocol,
    }
}

#[tokio::main]
async fn main() -> std::io::Result<()> {
    println!("Application started.");
    HttpServer::new(|| {
        App::new()
            .route("/ws", web::get().to(ws_handler))
    })
    .tcp_nodelay(true)
    .bind("0.0.0.0:8080")?
    .run()
    .await
}
