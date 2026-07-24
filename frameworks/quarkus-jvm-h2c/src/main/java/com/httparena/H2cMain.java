package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.DeploymentOptions;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.core.http.HttpServerRequest;
import io.vertx.core.http.HttpVersion;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Standalone Vert.x launcher (no Quarkus packaging).
 * Quarkus 3.17's runtime image omits netty-transport-native-epoll even when the
 * dep is declared in the pom — its package step filters classifier-carrying
 * jars from /app/lib/main. Dropping Quarkus and using a shaded fat jar lets the
 * native transport actually load, which is the prerequisite for
 * HttpServerOptions.setReusePort(true) to create a distinct listening socket
 * per verticle instance instead of sharing one accept thread across all cores.
 */
public class H2cMain {

    public static void main(String[] args) {
        // One Vertx instance per CPU. A single Vertx maintains a shared
        // NetServer registry that makes multiple HttpServer instances on the
        // same host:port fold into a single listening socket, even with
        // setReusePort(true). Separate Vertx instances each have their own
        // registry and bind independently — then SO_REUSEPORT on the kernel
        // side distributes accepts across the N sockets.
        int instances = Runtime.getRuntime().availableProcessors();
        VertxOptions vopts = new VertxOptions()
            .setPreferNativeTransport(true)
            .setEventLoopPoolSize(1);
        for (int i = 0; i < instances; i++) {
            Vertx vertx = Vertx.vertx(vopts);
            vertx.deployVerticle(new H2cVerticle());
        }
    }

    public static class H2cVerticle extends AbstractVerticle {

        private final ObjectMapper mapper = new ObjectMapper();
        private List<Map<String, Object>> dataset = List.of();

        @Override
        public void start() throws IOException {
            String path = System.getenv("DATASET_PATH");
            if (path == null) path = "/data/dataset.json";
            File f = new File(path);
            if (f.exists()) {
                dataset = mapper.readValue(f, new TypeReference<>() {});
            }

            HttpServerOptions opts = new HttpServerOptions()
                .setHost("0.0.0.0")
                .setPort(8082)
                .setUseAlpn(false)
                .setSsl(false)
                .setReusePort(true)
                .setTcpNoDelay(true)
                .setHttp2ClearTextEnabled(true);

            vertx.createHttpServer(opts)
                .requestHandler(this::handle)
                .listen();
        }

        private void handle(HttpServerRequest req) {
            // Anti-cheat: the h2c listener must refuse HTTP/1.1 requests.
            if (req.version() != HttpVersion.HTTP_2) {
                req.response()
                    .setStatusCode(400)
                    .putHeader("content-type", "text/plain")
                    .end("HTTP/2 cleartext prior-knowledge required");
                return;
            }

            String path = req.path();
            if ("/baseline2".equals(path)) {
                handleBaseline(req);
            } else if (path.startsWith("/json/")) {
                handleJson(req, path);
            } else {
                req.response().setStatusCode(404).end();
            }
        }

        private void handleBaseline(HttpServerRequest req) {
            int a = parseInt(req.getParam("a"), 0);
            int b = parseInt(req.getParam("b"), 0);
            req.response()
                .putHeader("content-type", "text/plain")
                .putHeader("server", "quarkus-jvm")
                .end(String.valueOf(a + b));
        }

        private void handleJson(HttpServerRequest req, String path) {
            int count;
            try {
                count = Integer.parseInt(path.substring("/json/".length()));
            } catch (NumberFormatException e) {
                count = 0;
            }
            if (count > dataset.size()) count = dataset.size();
            if (count < 0) count = 0;
            int m = parseInt(req.getParam("m"), 1);

            List<Map<String, Object>> items = new ArrayList<>(count);
            for (int i = 0; i < count; i++) {
                Map<String, Object> item = dataset.get(i);
                Map<String, Object> processed = new LinkedHashMap<>(item);
                int price = ((Number) item.get("price")).intValue();
                int quantity = ((Number) item.get("quantity")).intValue();
                processed.put("total", (long) price * quantity * m);
                items.add(processed);
            }
            try {
                byte[] body = mapper.writeValueAsBytes(Map.of("items", items, "count", items.size()));
                req.response()
                    .putHeader("content-type", "application/json")
                    .putHeader("server", "quarkus-jvm")
                    .end(Buffer.buffer(body));
            } catch (Exception e) {
                req.response().setStatusCode(500).end();
            }
        }

        private int parseInt(String s, int def) {
            if (s == null) return def;
            try {
                return Integer.parseInt(s);
            } catch (NumberFormatException e) {
                return def;
            }
        }
    }
}
