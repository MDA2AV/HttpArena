use trillium_websockets::{Message, WebSocketConn};

pub async fn ws_echo(mut conn: WebSocketConn) {
    use futures_lite::StreamExt;
    while let Some(Ok(msg)) = conn.next().await {
        match &msg {
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
            Message::Close(_) => break,
            Message::Text(_) | Message::Binary(_) => {}
        }
        if let Err(e) = conn.send(msg).await {
            log::debug!("ws send failed: {e}");
            break;
        }
    }
}
