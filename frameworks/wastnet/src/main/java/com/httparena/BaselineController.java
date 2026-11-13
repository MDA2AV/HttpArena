package com.httparena;

import io.github.wycst.wastnet.http.annotation.ContentType;
import io.github.wycst.wastnet.http.annotation.Endpoint;
import io.github.wycst.wastnet.http.annotation.RequestBody;
import io.github.wycst.wastnet.http.annotation.RequestParam;
import io.github.wycst.wastnet.http.annotation.RestController;

/** The plain-text sum endpoints: HTTP/1.1 baseline and the HTTP/2 baselines. */
@RestController
public class BaselineController {

    @Endpoint(value = "/baseline11", responseType = ContentType.TEXT)
    public String baseline11(@RequestParam("a") int a,
                             @RequestParam("b") int b,
                             @RequestBody String body) throws Exception {
        long sum = (long) a + b;
        if (body != null) {
            sum += Integer.parseInt(body);
        }
        return String.valueOf(sum);
    }

    @Endpoint(value = "/baseline2", responseType = ContentType.TEXT)
    public String baseline2(@RequestParam("a") int a, @RequestParam("b") int b) {
        return Long.toString((long) a + b);
    }

    @Endpoint(value = "/pipeline", responseType = ContentType.TEXT)
    public String pipeline() {
        return "ok";
    }
}
