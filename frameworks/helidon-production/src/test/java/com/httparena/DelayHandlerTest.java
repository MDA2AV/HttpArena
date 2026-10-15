package com.httparena;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.Socket;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import io.helidon.webserver.WebServer;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

class DelayHandlerTest {
    @Test
    void overlappingRequestsUseIndependentDelays() throws Exception {
        WebServer server = WebServer.builder()
                .host("127.0.0.1")
                .port(0)
                .routing(routing -> routing.get("/delay/{ms}", new DelayHandler()))
                .build()
                .start();
        try (var client = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build()) {
            var results = new ArrayList<CompletableFuture<Void>>();
            for (int i = 0; i < 32; i++) {
                int millis = 100 + (i * 13) % 400;
                var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + server.port() + "/delay/" + millis))
                        .timeout(Duration.ofSeconds(5))
                        .build();
                long started = System.nanoTime();
                results.add(client.sendAsync(request, HttpResponse.BodyHandlers.ofString()).thenAccept(response -> {
                    assertEquals(200, response.statusCode());
                    assertEquals(Integer.toString(millis), response.body());
                    assertEquals("text/plain", response.headers().firstValue("content-type").orElseThrow());
                    assertTrue(System.nanoTime() - started >= TimeUnit.MILLISECONDS.toNanos(millis),
                               "Request for " + millis + " ms returned early");
                }));
            }
            CompletableFuture.allOf(results.toArray(CompletableFuture[]::new)).get(10, TimeUnit.SECONDS);
        } finally {
            server.stop();
        }
    }

    @Test
    void eachRequestOnOneConnectionUsesItsOwnDelayAndRequestThread() throws Exception {
        var observations = new LinkedBlockingQueue<Observation>();
        var handler = new DelayHandler();
        WebServer server = WebServer.builder()
                .host("127.0.0.1")
                .port(0)
                .routing(routing -> routing.get("/delay/{ms}", (req, res) -> {
                    Thread requestThread = Thread.currentThread();
                    long started = System.nanoTime();
                    handler.handle(req, res);
                    observations.add(new Observation(requestThread, Thread.currentThread(), System.nanoTime() - started));
                }))
                .build()
                .start();
        try (var socket = new Socket("127.0.0.1", server.port())) {
            socket.setSoTimeout(5_000);
            var reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.ISO_8859_1));
            for (int millis : List.of(0, 10, 500, 1, 37)) {
                String request = "GET /delay/" + millis + " HTTP/1.1\r\nHost: localhost\r\n\r\n";
                socket.getOutputStream().write(request.getBytes(StandardCharsets.ISO_8859_1));
                assertEquals("HTTP/1.1 200 OK", reader.readLine());
                int contentLength = -1;
                String contentType = null;
                for (String line = reader.readLine(); line != null && !line.isEmpty(); line = reader.readLine()) {
                    String[] header = line.split(":", 2);
                    if (header[0].equalsIgnoreCase("content-length")) {
                        contentLength = Integer.parseInt(header[1].trim());
                    } else if (header[0].equalsIgnoreCase("content-type")) {
                        contentType = header[1].trim();
                    }
                }
                assertEquals(Integer.toString(millis).length(), contentLength);
                assertEquals("text/plain", contentType);
                char[] body = new char[contentLength];
                for (int offset = 0; offset < contentLength;) {
                    int count = reader.read(body, offset, contentLength - offset);
                    assertTrue(count > 0, "Response body ended early");
                    offset += count;
                }
                assertEquals(Integer.toString(millis), new String(body));
                Observation observation = observations.poll(5, TimeUnit.SECONDS);
                assertNotNull(observation, "Handler did not finish on request thread");
                assertTrue(observation.before().isVirtual());
                assertSame(observation.before(), observation.after());
                assertTrue(observation.elapsedNanos() >= TimeUnit.MILLISECONDS.toNanos(millis),
                           "Requested " + millis + " ms, elapsed " + observation.elapsedNanos() + " ns");
            }
        } finally {
            server.stop();
        }
    }

    private record Observation(Thread before, Thread after, long elapsedNanos) {
    }
}
