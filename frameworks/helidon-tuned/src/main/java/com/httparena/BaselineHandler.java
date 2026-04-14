package com.httparena;

import java.nio.charset.StandardCharsets;

import io.helidon.common.uri.UriQuery;
import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static com.httparena.Main.SERVER_HEADER;
import static io.helidon.http.HeaderValues.CONTENT_TYPE_TEXT_PLAIN;

class BaselineHandler implements Handler {
    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        res.header(SERVER_HEADER);
        res.header(CONTENT_TYPE_TEXT_PLAIN);

        UriQuery query = req.query();
        int first = Integer.parseInt(query.getRaw("a"));
        int second = Integer.parseInt(query.getRaw("b"));

        res.send(String.valueOf(first + second).getBytes(StandardCharsets.US_ASCII));
    }
}
