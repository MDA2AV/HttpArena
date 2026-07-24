//! HttpArena WebSocket echo server for mq-bridge (Rust).
//!
//! Accepts WebSocket upgrades on `0.0.0.0:8080` at path `/ws` and echoes each
//! inbound frame back on the same connection (the `echo-ws` profiles).
//!
//! The route is `websocket -> response`: mq-bridge's direct WebSocket path
//! echoes each inbound text/binary frame back on the originating socket.

use mq_bridge::models::{Endpoint, EndpointType, WebSocketConfig, WebSocketExecutionMode};
use mq_bridge::Route;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let listen = std::env::var("MQB_LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());

    let ws = WebSocketConfig::new(listen)
        .with_path("/ws")
        .with_execution_mode(WebSocketExecutionMode::DirectOnly);
    let input = Endpoint::new(EndpointType::WebSocket(ws));

    let output = Endpoint::new_response();

    let route = Route::new(input, output);
    let handle = route.run("httparena-ws").await?;
    handle.join().await?;
    Ok(())
}
