package com.httparena;

import io.github.wycst.wastnet.http.annotation.WebSocket;
import io.github.wycst.wastnet.http.upgrade.websocket.WebSocketConnection;
import io.github.wycst.wastnet.http.upgrade.websocket.WebSocketResource;

import java.io.IOException;

/** {@code /ws} echo endpoint, registered by the annotation package scan. */
@WebSocket("/ws")
public class EchoWebSocket extends WebSocketResource {

    public EchoWebSocket() {
        super(false);
    }

    @Override
    public void onMessage(WebSocketConnection connection, byte[] data) throws IOException {
        connection.sendText(data);
    }

    @Override
    public void onBinary(WebSocketConnection connection, byte[] data) throws IOException {
        connection.sendBinary(data);
    }
}
