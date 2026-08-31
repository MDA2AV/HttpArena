package com.httparena;

import java.io.IOException;
import java.io.InputStream;

import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

class EchoHandler implements Handler {
    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        res.header("Content-Type", "application/octet-stream");

        // Collected: the response needs a Content-Length, and a chunked
        // request carries none to forward until the body is in.
        try (InputStream is = req.content().inputStream()) {
            res.send(is.readAllBytes());
        } catch (IOException ignored) {
            // client went away; nothing to write to
        }
    }
}
