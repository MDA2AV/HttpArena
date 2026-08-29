package com.httparena.spring.boot;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.InputStream;

@RestController
@RequestMapping("/echo")
public class EchoController {
    // Collected: the response needs a Content-Length, and a chunked request
    // carries none to forward until the body is in.
    @PostMapping(consumes = MediaType.ALL_VALUE, produces = MediaType.APPLICATION_OCTET_STREAM_VALUE)
    public byte[] echoBody(InputStream body) throws IOException {
        return body.readAllBytes();
    }
}
