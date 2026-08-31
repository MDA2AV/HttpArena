package com.httparena;

import java.nio.charset.StandardCharsets;

import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static io.helidon.http.HeaderValues.CONTENT_TYPE_TEXT_PLAIN;

final class DelayHandler implements Handler {
    @Override
    public void handle(ServerRequest req, ServerResponse res) throws InterruptedException {
        int delay = Integer.parseInt(req.path().pathParameters().get("ms"));

        Thread.sleep(delay);

        res.header(CONTENT_TYPE_TEXT_PLAIN);
        res.send(Integer.toString(delay).getBytes(StandardCharsets.US_ASCII));
    }
}
