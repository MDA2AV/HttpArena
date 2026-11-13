package com.httparena;

import io.github.wycst.wastnet.http.annotation.ContentType;
import io.github.wycst.wastnet.http.annotation.Endpoint;
import io.github.wycst.wastnet.http.annotation.PathParam;
import io.github.wycst.wastnet.http.annotation.RestController;

/**
 * {@code GET /delay/{ms}} — the async profile holds one connection per in-flight
 * request and the server sleeps for the requested duration, so the benchmark
 * measures how many timers the runtime can keep live at once.
 */
@RestController
public class DelayController {

    @Endpoint(value = "/delay/{ms}", async = true,  responseType = ContentType.TEXT)
    public String delay(@PathParam("ms") long ms) throws Exception {
        if (ms > 0) {
            Thread.sleep(ms);
        }
        return Long.toString(ms);
    }
}
