package com.httparena;

import java.io.ByteArrayInputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.zip.GZIPInputStream;

import io.helidon.json.binding.JsonBinding;
import io.helidon.webserver.WebServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;

class JsonHandlerTest {
    private static final JsonBinding JSON_BINDING = JsonBinding.create();
    private static final String LARGE_NAME = "雪".repeat(6000);

    @TempDir
    Path dataDirectory;

    private WebServer server;
    private HttpClient client;

    @BeforeEach
    void startServer() throws Exception {
        Files.writeString(dataDirectory.resolve("dataset.json"), """
                [
                  {"id":1,"name":"Café \\"alpha\\"\\\\line\\nnext","category":"first",
                   "price":7,"quantity":3,"active":true,"tags":["日本語","a\\tb"],
                   "rating":{"score":4,"count":11}},
                  {"id":2,"name":"second","category":"other",
                   "price":2000000000,"quantity":4,"active":false,"tags":[],
                   "rating":{"score":2,"count":3000000000}},
                  {"id":3,"name":"%s","category":"large",
                   "price":0,"quantity":5,"active":true,"tags":["large"],
                   "rating":{"score":5,"count":1}}
                ]
                """.formatted(LARGE_NAME));
        JsonHandler handler = new JsonHandler(dataDirectory.toString());
        server = WebServer.builder()
                .host("127.0.0.1")
                .port(0)
                .routing(routing -> routing.get("/json/{count}", handler))
                .build()
                .start();
        client = HttpClient.newBuilder()
                .version(HttpClient.Version.HTTP_1_1)
                .connectTimeout(Duration.ofSeconds(10))
                .build();
    }

    @AfterEach
    void stopServer() {
        if (client != null) {
            client.close();
        }
        if (server != null) {
            server.stop();
        }
    }

    @ParameterizedTest(name = "gzip count={0}, multiplier={1}, returned count={2}")
    @CsvSource({"0,3,0", "-1,3,0", "1,3,1", "5,-2,3", "3,0,3"})
    void gzipResponseHasCompleteJsonAndTrailer(int count, int multiplier, int expectedCount) throws Exception {
        HttpResponse<byte[]> response = request("/json/" + count + "?m=" + multiplier, true);

        assertHeaders(response);
        assertEquals("gzip", response.headers().firstValue("Content-Encoding").orElseThrow());
        byte[] decoded;
        try (GZIPInputStream gzip = new GZIPInputStream(new ByteArrayInputStream(response.body()))) {
            // Reading through EOF verifies the gzip checksum and uncompressed-size trailer.
            decoded = gzip.readAllBytes();
            assertEquals(-1, gzip.read(), "gzip stream must end after the complete JSON response");
        }
        assertEquals(expectedItems(expectedCount, multiplier), JSON_BINDING.deserialize(decoded, TotalItems.class));
    }

    @Test
    void responseWithoutAcceptEncodingRemainsUncompressed() throws Exception {
        HttpResponse<byte[]> response = request("/json/3?m=2", false);

        assertHeaders(response);
        assertFalse(response.headers().firstValue("Content-Encoding").isPresent(), "unexpected content encoding");
        assertEquals(expectedItems(3, 2), JSON_BINDING.deserialize(response.body(), TotalItems.class));
    }

    @Test
    void responseDefaultsToMultiplierOne() throws Exception {
        HttpResponse<byte[]> response = request("/json/1?unused=1", false);

        assertHeaders(response);
        assertEquals(expectedItems(1, 1), JSON_BINDING.deserialize(response.body(), TotalItems.class));
    }

    private HttpResponse<byte[]> request(String path, boolean gzip) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + server.port() + path))
                .timeout(Duration.ofSeconds(10));
        if (gzip) {
            request.header("Accept-Encoding", "gzip");
        }
        return client.send(request.build(), HttpResponse.BodyHandlers.ofByteArray());
    }

    private static void assertHeaders(HttpResponse<byte[]> response) {
        assertEquals(200, response.statusCode(), "HTTP status");
        assertEquals("application/json", response.headers().firstValue("Content-Type").orElseThrow());
        assertEquals("Accept-Encoding", response.headers().firstValue("Vary").orElseThrow());
        assertEquals(response.body().length, response.headers().firstValueAsLong("Content-Length").orElseThrow(),
                     "Content-Length must describe the transmitted bytes");
    }

    private static TotalItems expectedItems(int count, int multiplier) {
        List<TotalItem> items = List.of(
                new TotalItem(1, "Café \"alpha\"\\line\nnext", "first", 7, 3, true,
                              List.of("日本語", "a\tb"), new Rating(4, 11), 21L * multiplier),
                new TotalItem(2, "second", "other", 2000000000, 4, false,
                              List.of(), new Rating(2, 3000000000L), 8000000000L * multiplier),
                new TotalItem(3, LARGE_NAME, "large", 0, 5, true,
                              List.of("large"), new Rating(5, 1), 0));
        return new TotalItems(items.subList(0, count), count);
    }
}
