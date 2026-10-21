package httparena;

import io.micronaut.websocket.WebSocketSession;
import io.micronaut.websocket.annotation.OnMessage;
import io.micronaut.websocket.annotation.ServerWebSocket;
import org.reactivestreams.Publisher;

/** Echoes every text and binary frame back on the same session. */
@ServerWebSocket("/ws")
public class EchoWebSocket {

    @OnMessage
    public Publisher<String> onText(String message, WebSocketSession session) {
        return session.send(message);
    }

    @OnMessage
    public Publisher<byte[]> onBinary(byte[] message, WebSocketSession session) {
        return session.send(message);
    }
}
