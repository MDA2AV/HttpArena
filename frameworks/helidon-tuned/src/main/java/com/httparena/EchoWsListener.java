package com.httparena;

import io.helidon.common.buffers.BufferData;
import io.helidon.websocket.WsListener;
import io.helidon.websocket.WsSession;

final class EchoWsListener implements WsListener {
    @Override
    public void onMessage(WsSession session, String text, boolean last) {
        session.send(text, last);
    }

    @Override
    public void onMessage(WsSession session, BufferData buffer, boolean last) {
        session.send(buffer, last);
    }

    @Override
    public void onPing(WsSession session, BufferData buffer) {
        session.pong(buffer);
    }
}
