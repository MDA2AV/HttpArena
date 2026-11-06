package com.httparena;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;

import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static io.helidon.http.HeaderValues.CONTENT_TYPE_TEXT_PLAIN;

/**
 * GET /rendezvous/{key}?v= - the first request for a key waits, the second answers both.
 * Each request has a virtual thread of its own, so waiting is just blocking on a future.
 */
final class RendezvousHandler implements Handler {
    private record Waiter(String value, CompletableFuture<String> reply) {}

    private final ConcurrentHashMap<String, Waiter> waiting = new ConcurrentHashMap<>();

    @Override
    public void handle(ServerRequest req, ServerResponse res) throws Exception {
        String key = req.path().pathParameters().get("key");
        String value = req.query().first("v").orElse("");

        Waiter mine = null;
        String other;
        while (true) {
            Waiter peer = waiting.remove(key);
            if (peer != null) {
                peer.reply().complete(value);
                other = peer.value();
                break;
            }
            if (mine == null) {
                mine = new Waiter(value, new CompletableFuture<>());
            }
            if (waiting.putIfAbsent(key, mine) == null) {
                other = mine.reply().get();
                break;
            }
        }

        res.header(CONTENT_TYPE_TEXT_PLAIN);
        res.send(other.getBytes(StandardCharsets.ISO_8859_1));
    }
}
