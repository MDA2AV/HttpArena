use trillium_websockets::{Message, WebSocketConn};

pub async fn ws_echo(mut conn: WebSocketConn) {
    use futures_lite::StreamExt;
    while let Some(Ok(msg)) = conn.next().await {
        let result = match msg {
            Message::Text(t) => conn.send_string(t.to_string()).await,
            Message::Binary(b) => conn.send_bytes(b.to_vec()).await,
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
            Message::Close(_) => break,
        };
        if let Err(e) = result {
            log::debug!("ws send failed: {e}");
            break;
        }
    }
}
