package httparena;

import io.micronaut.context.ApplicationContext;
import io.micronaut.http.ServerHttpRequest;
import io.micronaut.http.body.ByteBody;
import io.micronaut.http.body.CloseableByteBody;
import io.micronaut.http.body.stream.BodySizeLimits;
import io.micronaut.http.body.stream.BufferConsumer;
import io.micronaut.http.netty.body.NettyByteBodyFactory;
import io.micronaut.runtime.server.EmbeddedServer;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.embedded.EmbeddedChannel;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.lang.reflect.Proxy;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;

import static org.junit.jupiter.api.Assertions.*;

class EchoControllerTest {
    @Test
    void forwardsNativeStorageWithoutConsumingTheRequestsBody() {
        EmbeddedChannel channel = new EmbeddedChannel();
        try {
            NettyByteBodyFactory factory = new NettyByteBodyFactory(channel);
            ByteBuf bytes = Unpooled.directBuffer().writeBytes(new byte[]{0, -1, 1, -128});
            long address = bytes.memoryAddress();
            try (CloseableByteBody original = factory.adapt(bytes)) {
                ByteBuf forwarded = echo(original).join();
                try {
                    assertEquals(address, forwarded.memoryAddress());
                    assertArrayEquals(new byte[]{0, -1, 1, -128}, original.buffer().join().toByteArray());
                    assertEquals(4, forwarded.readableBytes());
                } finally {
                    forwarded.release();
                }
            }
            assertEquals(0, bytes.refCnt());
        } finally {
            channel.finishAndReleaseAll();
        }
    }

    @Test
    void cancellationAndReadFailureReleaseBufferedNativeStorage() {
        EmbeddedChannel channel = new EmbeddedChannel();
        try {
            NettyByteBodyFactory factory = new NettyByteBodyFactory(channel);
            for (boolean cancel : new boolean[]{false, true}) {
                var source = factory.createStreamingBody(BodySizeLimits.UNLIMITED, new BufferConsumer.Upstream() {
                    @Override
                    public void onBytesConsumed(long bytes) {
                    }
                });
                ByteBuf bytes = Unpooled.directBuffer().writeByte(42);
                CompletableFuture<ByteBuf> response = echo(source.rootBody());
                source.sharedBuffer().add(factory.readBufferFactory().adapt(bytes));
                assertFalse(response.isDone());
                if (cancel) {
                    assertTrue(response.cancel(false));
                    source.sharedBuffer().complete();
                } else {
                    source.sharedBuffer().error(new IllegalStateException("read failed"));
                    assertThrows(CompletionException.class, response::join);
                }
                source.rootBody().close();
                assertEquals(0, bytes.refCnt());
            }
        } finally {
            channel.finishAndReleaseAll();
        }
    }

    @Test
    void echoesEmptyBinaryLargeAndChunkedBodies() throws Exception {
        try (ApplicationContext context = serverContext(Map.of());
             HttpClient client = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build()) {
            EmbeddedServer server = context.getBean(EmbeddedServer.class).start();
            URI uri = URI.create("http://localhost:" + server.getPort() + "/echo");
            for (int size : new int[]{0, 256 * 1024, 20 * 1024 * 1024, 32 * 1024 * 1024}) {
                byte[] body = new byte[size];
                for (int i = 0; i < size; i++) {
                    body[i] = (byte) i;
                }
                for (boolean chunked : new boolean[]{false, true}) {
                    if (chunked && (size == 0 || size == 32 * 1024 * 1024)) {
                        continue;
                    }
                    var publisher = chunked ? HttpRequest.BodyPublishers.ofInputStream(() -> new ByteArrayInputStream(body))
                            : HttpRequest.BodyPublishers.ofByteArray(body);
                    HttpResponse<byte[]> response = client.send(HttpRequest.newBuilder(uri).timeout(Duration.ofSeconds(30))
                            .header("Content-Type", "application/octet-stream").POST(publisher).build(), HttpResponse.BodyHandlers.ofByteArray());
                    assertEquals(200, response.statusCode());
                    assertEquals("application/octet-stream", response.headers().firstValue("content-type").orElseThrow());
                    assertArrayEquals(body, response.body());
                }
            }
            try (Socket socket = new Socket("localhost", server.getPort())) {
                var output = socket.getOutputStream();
                output.write(("POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n"
                        + "4\r\npart\r\n").getBytes(StandardCharsets.US_ASCII));
                output.flush();
                socket.setSoTimeout(200);
                assertThrows(SocketTimeoutException.class, () -> socket.getInputStream().read());
                output.write("4\r\nlast\r\n0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                output.flush();
                socket.setSoTimeout(5000);
                assertTrue(readHead(socket.getInputStream()).startsWith("HTTP/1.1 200 "));
                assertArrayEquals("partlast".getBytes(StandardCharsets.US_ASCII), socket.getInputStream().readNBytes(8));
            }
        }
    }

    @Test
    void rejectsRequestAndBufferOverflowsBeforeWritingSuccessHeaders() throws Exception {
        for (String limit : new String[]{"micronaut.server.max-request-size", "micronaut.server.max-request-buffer-size"}) {
            try (ApplicationContext context = serverContext(Map.of(limit, "1KB"))) {
                EmbeddedServer server = context.getBean(EmbeddedServer.class).start();
                for (boolean chunked : new boolean[]{false, true}) {
                    try (Socket socket = new Socket("localhost", server.getPort())) {
                        socket.setSoTimeout(5000);
                        var output = socket.getOutputStream();
                        output.write(("POST /echo HTTP/1.1\r\nHost: localhost\r\n"
                                + (chunked ? "Transfer-Encoding: chunked" : "Content-Length: 2048") + "\r\n\r\n")
                                .getBytes(StandardCharsets.US_ASCII));
                        if (chunked) {
                            output.write("800\r\n".getBytes(StandardCharsets.US_ASCII));
                        }
                        output.write(new byte[2048]);
                        if (chunked) {
                            output.write("\r\n0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                        }
                        output.flush();
                        String head = readHead(socket.getInputStream());
                        assertTrue(head.startsWith("HTTP/1.1 413 "), head);
                    }
                }
            }
        }
    }

    private static CompletableFuture<ByteBuf> echo(ByteBody body) {
        ServerHttpRequest<?> request = (ServerHttpRequest<?>) Proxy.newProxyInstance(
                ServerHttpRequest.class.getClassLoader(), new Class<?>[]{ServerHttpRequest.class},
                (proxy, method, args) -> {
                    assertEquals("byteBody", method.getName());
                    return body;
                });
        return new BenchmarkController(null).echoBody(request);
    }

    static ApplicationContext serverContext(Map<String, Object> overrides) {
        Map<String, Object> properties = new HashMap<>(overrides);
        for (String listener : new String[]{"http", "https", "h2tls", "h2c", "h3"}) {
            properties.put("micronaut.server.netty.listeners." + listener + ".port", -1);
            properties.put("micronaut.server.netty.listeners." + listener + ".ssl", false);
            properties.put("micronaut.server.netty.listeners." + listener + ".family", "TCP");
        }
        properties.put("micronaut.netty.event-loops.default.num-threads", 2);
        return ApplicationContext.run(properties);
    }

    private static String readHead(InputStream input) throws Exception {
        ByteArrayOutputStream head = new ByteArrayOutputStream();
        int matched = 0;
        while (matched < 4) {
            int b = input.read();
            assertTrue(b >= 0, head.toString(StandardCharsets.US_ASCII));
            head.write(b);
            matched = (b == '\r' && (matched == 0 || matched == 2)) || (b == '\n' && (matched == 1 || matched == 3)) ? matched + 1 : 0;
        }
        return head.toString(StandardCharsets.US_ASCII);
    }
}
