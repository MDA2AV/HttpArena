package com.httparena;

import java.nio.charset.StandardCharsets;

import io.helidon.http.Header;
import io.helidon.http.HeaderNames;
import io.helidon.http.HeaderValues;
import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static com.httparena.Main.SERVER_HEADER;
import static io.helidon.http.HeaderValues.CONTENT_TYPE_TEXT_PLAIN;

class PipelineHandler implements Handler {
    private static final byte[] RESPONSE = "ok".getBytes(StandardCharsets.US_ASCII);
    private static final Header CONTENT_LENGTH = HeaderValues.createCached(HeaderNames.CONTENT_LENGTH, "2");

    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        res.header(SERVER_HEADER);
        res.header(CONTENT_TYPE_TEXT_PLAIN);
        res.header(CONTENT_LENGTH);
        res.send(RESPONSE);
    }
}
