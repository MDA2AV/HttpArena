package httparena;

import org.reactivestreams.Subscriber;
import org.reactivestreams.Subscription;

import com.linecorp.armeria.common.websocket.CloseWebSocketFrame;
import com.linecorp.armeria.common.websocket.WebSocket;
import com.linecorp.armeria.common.websocket.WebSocketFrame;
import com.linecorp.armeria.common.websocket.WebSocketWriter;
import com.linecorp.armeria.server.ServiceRequestContext;
import com.linecorp.armeria.server.websocket.WebSocketServiceHandler;

/** Echoes text and binary frames, answers pings and returns the close handshake. */
final class EchoWebSocketHandler implements WebSocketServiceHandler {

    @Override
    public WebSocket handle(ServiceRequestContext ctx, WebSocket in) {
        final WebSocketWriter out = WebSocket.streaming();
        in.subscribe(new Subscriber<WebSocketFrame>() {
            @Override
            public void onSubscribe(Subscription s) {
                s.request(Long.MAX_VALUE);
            }

            @Override
            public void onNext(WebSocketFrame frame) {
                switch (frame.type()) {
                    case TEXT, BINARY, CONTINUATION -> out.write(frame);
                    case PING -> {
                        out.writePong(frame.array());
                        frame.close();
                    }
                    case CLOSE -> {
                        final CloseWebSocketFrame close = (CloseWebSocketFrame) frame;
                        out.close(close.status(), close.reasonPhrase());
                        frame.close();
                    }
                    default -> frame.close();
                }
            }

            @Override
            public void onError(Throwable t) {
                out.close(t);
            }

            @Override
            public void onComplete() {
                out.close();
            }
        });
        return out;
    }
}
