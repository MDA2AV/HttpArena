package com.httparena.spring.boot;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.databind.json.JsonMapper;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.zip.GZIPInputStream;
import java.util.zip.InflaterInputStream;

/**
 * POST /parse — the resilience suite's parser-differential sink. Decompresses
 * Content-Encoding (the decompression-bomb / codec-bypass target), then parses the
 * body with Spring's standard facility by content-type: JSON through Jackson into a
 * dynamic tree (its recursion, number and key handling — what the nesting-bomb,
 * bignum and hashdos target), urlencoded split into key/value pairs, multipart split
 * on the boundary. Anything else is just the buffered decompressed body. Robustness
 * comes from Jackson's standard StreamReadConstraints (depth/number caps) and the
 * JDK's collision-resistant maps, not from a fixed schema.
 * See site/content/docs/test-profiles/resilience/.
 */
@RestController
@RequestMapping("/parse")
public class ParseController {

    private final JsonMapper jsonMapper;

    public ParseController(JsonMapper jsonMapper) {
        this.jsonMapper = jsonMapper;
    }

    @PostMapping(consumes = MediaType.ALL_VALUE, produces = MediaType.TEXT_PLAIN_VALUE)
    public String parse(HttpServletRequest request) throws IOException {
        byte[] data = decompress(request.getInputStream().readAllBytes(), request.getHeader("Content-Encoding"));
        String contentType = request.getContentType();
        contentType = contentType == null ? "" : contentType.toLowerCase(Locale.ROOT);

        if (contentType.contains("application/json")) {
            // Dynamic parse into a Jackson tree — no fixed schema. A malformed or
            // hostile payload is fine: the parse ran, which is the point.
            try {
                jsonMapper.readTree(data);
            } catch (RuntimeException ignored) {
                // StreamReadConstraints etc. rejecting the payload is a survival, not a failure.
            }
        } else if (contentType.contains("application/x-www-form-urlencoded")) {
            // Split into key/value pairs (per-pair work).
            for (String pair : new String(data, StandardCharsets.ISO_8859_1).split("&")) {
                pair.indexOf('=');
            }
        } else if (contentType.contains("multipart/form-data")) {
            // Split on the boundary (per-part work).
            int i = contentType.indexOf("boundary=");
            if (i >= 0) {
                byte[] boundary = ("--" + contentType.substring(i + 9).trim().replace("\"", ""))
                        .getBytes(StandardCharsets.ISO_8859_1);
                countOccurrences(data, boundary);
            }
        }
        return "ok";
    }

    // Decompress the request body (unbounded, on purpose) so the parser sees the
    // inflated form — what a decompression bomb targets.
    private static byte[] decompress(byte[] raw, String contentEncoding) throws IOException {
        if (contentEncoding == null) {
            return raw;
        }
        String ce = contentEncoding.toLowerCase(Locale.ROOT);
        final InputStream in;
        if (ce.contains("gzip")) {
            in = new GZIPInputStream(new ByteArrayInputStream(raw));
        } else if (ce.contains("deflate")) {
            in = new InflaterInputStream(new ByteArrayInputStream(raw));
        } else {
            return raw;
        }
        try (in) {
            return in.readAllBytes();
        }
    }

    private static int countOccurrences(byte[] data, byte[] pattern) {
        if (pattern.length == 0 || data.length < pattern.length) {
            return 0;
        }
        int count = 0;
        outer:
        for (int i = 0; i <= data.length - pattern.length; i++) {
            for (int j = 0; j < pattern.length; j++) {
                if (data[i + j] != pattern[j]) {
                    continue outer;
                }
            }
            count++;
        }
        return count;
    }
}
