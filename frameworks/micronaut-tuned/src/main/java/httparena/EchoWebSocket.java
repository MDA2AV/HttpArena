package httparena;

import io.micronaut.websocket.WebSocketSession;
import io.micronaut.websocket.annotation.OnMessage;
import io.micronaut.websocket.annotation.ServerWebSocket;
import io.netty.buffer.ByteBufUtil;
import io.netty.handler.codec.http.websocketx.TextWebSocketFrame;
import io.netty.handler.codec.http.websocketx.WebSocketFrame;
import org.reactivestreams.Publisher;

/**
 * Echoes every frame back on the same session, a text frame as a text frame and a binary frame as
 * a binary frame. The frame itself is taken so that its type is known, and released here.
 */
@ServerWebSocket("/ws")
public class EchoWebSocket {

    @OnMessage
    public Publisher<?> onMessage(WebSocketFrame frame, WebSocketSession session) {
        try {
            if (frame instanceof TextWebSocketFrame text) {
                return session.send(text.text());
            }
            return session.send(ByteBufUtil.getBytes(frame.content()));
        } finally {
            frame.release();
        }
    }
}
