use actix_web::{web, App, HttpServer, HttpRequest, HttpResponse};
use actix_ws;

async fn ws_handler(req: HttpRequest, body: web::Payload) -> actix_web::Result<HttpResponse> {
    let (response, mut session, mut msg_stream) = actix_ws::handle(&req, body)?;
    actix_web::rt::spawn(async move {
        while let Some(Ok(msg)) = msg_stream.recv().await {
            match msg {
                actix_ws::Message::Text(text) => { let _ = session.text(text).await; }
                actix_ws::Message::Binary(bin) => { let _ = session.binary(bin).await; }
                actix_ws::Message::Ping(bytes) => { let _ = session.pong(&bytes).await; }
                actix_ws::Message::Close(_) => break,
                _ => {}
            }
        }
    });
    Ok(response)
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
