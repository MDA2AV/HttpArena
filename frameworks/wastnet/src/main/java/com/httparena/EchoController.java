package com.httparena;

import io.github.wycst.wastnet.http.HttpMethod;
import io.github.wycst.wastnet.http.HttpRequest;
import io.github.wycst.wastnet.http.HttpResponse;
import io.github.wycst.wastnet.http.annotation.ContentType;
import io.github.wycst.wastnet.http.annotation.Endpoint;
import io.github.wycst.wastnet.http.annotation.Controller;

import java.io.IOException;

/** {@code POST /echo} — returns the request body verbatim (8gbit profile). */
@Controller
public class EchoController {

    @Endpoint(value = "/echo", allowMethods = {HttpMethod.POST})
    public void echo(HttpRequest request, HttpResponse response) throws IOException {
        byte[] body = request.isStream()
                ? request.bodyStream().readAllBytes()
                : request.getBodyData();
        response.contentType("application/octet-stream").body(body);
    }
}
