package com.httparena;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static com.httparena.Main.SERVER_HEADER;
import static io.helidon.http.HeaderValues.CONTENT_TYPE_TEXT_PLAIN;

class UploadHandler implements Handler {
    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        res.header(SERVER_HEADER);
        res.header(CONTENT_TYPE_TEXT_PLAIN);

        try (InputStream is = req.content().inputStream()) {
            long bodyLength = is.transferTo(OutputStream.nullOutputStream());
            res.send(String.valueOf(bodyLength));
        } catch (IOException ignored) {
            // ignore client errors (i.e. disconnect), as we can only fail on IO exception here, so
            // there is nowhere to write to
        }
    }
}
