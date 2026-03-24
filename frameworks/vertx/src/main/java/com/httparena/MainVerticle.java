package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.vertx.core.*;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.http.*;
import io.vertx.core.net.PemKeyCertOptions;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.handler.BodyHandler;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.sql.*;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

public class MainVerticle extends AbstractVerticle {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Buffer OK_BUFFER = Buffer.buffer("ok");

    // Shared pre-computed data (loaded once, shared across verticle instances)
    private static volatile List<Map<String, Object>> dataset;
    private static volatile byte[] jsonResponse;
    private static volatile byte[] largeJsonResponse;
    private static final Map<String, byte[]> staticFiles = new ConcurrentHashMap<>();
    private static final Map<String, String> MIME_TYPES = Map.ofEntries(
        Map.entry(".css", "text/css"),
        Map.entry(".js", "application/javascript"),
        Map.entry(".html", "text/html"),
        Map.entry(".woff2", "font/woff2"),
        Map.entry(".svg", "image/svg+xml"),
        Map.entry(".webp", "image/webp"),
        Map.entry(".json", "application/json")
    );

    private static final Object INIT_LOCK = new Object();
    private static volatile boolean dataInitialized = false;

    // Per-verticle DB connection (one per event loop — no contention)
    private Connection dbConn;
    private PreparedStatement dbStmt;

    public static void main(String[] args) {
        int instances = Runtime.getRuntime().availableProcessors();
        VertxOptions vertxOpts = new VertxOptions()
            .setPreferNativeTransport(true)
            .setEventLoopPoolSize(instances);

        Vertx vertx = Vertx.vertx(vertxOpts);

        // Pre-load shared data before deploying verticles
        initSharedData();

        DeploymentOptions deployOpts = new DeploymentOptions().setInstances(instances);
        vertx.deployVerticle(MainVerticle.class.getName(), deployOpts)
            .onSuccess(id -> System.out.println("Deployed " + instances + " instances"))
            .onFailure(err -> {
                err.printStackTrace();
                System.exit(1);
            });
    }

    private static void initSharedData() {
        if (dataInitialized) return;
        synchronized (INIT_LOCK) {
            if (dataInitialized) return;
            try {
                // Dataset
                String path = System.getenv("DATASET_PATH");
                if (path == null) path = "/data/dataset.json";
                File f = new File(path);
                if (f.exists()) {
                    dataset = MAPPER.readValue(f, new TypeReference<>() {});
                    // Pre-compute /json response
                    List<Map<String, Object>> items = new ArrayList<>(dataset.size());
                    for (Map<String, Object> item : dataset) {
                        Map<String, Object> processed = new LinkedHashMap<>(item);
                        double price = ((Number) item.get("price")).doubleValue();
                        int quantity = ((Number) item.get("quantity")).intValue();
                        processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
                        items.add(processed);
                    }
                    jsonResponse = MAPPER.writeValueAsBytes(Map.of("items", items, "count", items.size()));
                }

                // Large dataset for compression
                File largef = new File("/data/dataset-large.json");
                if (largef.exists()) {
                    List<Map<String, Object>> largeDataset = MAPPER.readValue(largef, new TypeReference<>() {});
                    List<Map<String, Object>> largeItems = new ArrayList<>(largeDataset.size());
                    for (Map<String, Object> item : largeDataset) {
                        Map<String, Object> processed = new LinkedHashMap<>(item);
                        double price = ((Number) item.get("price")).doubleValue();
                        int quantity = ((Number) item.get("quantity")).intValue();
                        processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
                        largeItems.add(processed);
                    }
                    largeJsonResponse = MAPPER.writeValueAsBytes(Map.of("items", largeItems, "count", largeItems.size()));
                }

                // Static files
                File staticDir = new File("/data/static");
                if (staticDir.isDirectory()) {
                    File[] files = staticDir.listFiles();
                    if (files != null) {
                        for (File sf : files) {
                            if (sf.isFile()) {
                                staticFiles.put(sf.getName(), Files.readAllBytes(sf.toPath()));
                            }
                        }
                    }
                }
            } catch (Exception e) {
                e.printStackTrace();
            }
            dataInitialized = true;
        }
    }

    @Override
    public void start(Promise<Void> startPromise) {
        // Per-verticle DB connection
        File dbFile = new File("/data/benchmark.db");
        if (dbFile.exists()) {
            try {
                dbConn = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1");
                dbConn.createStatement().execute("PRAGMA mmap_size=268435456");
                dbStmt = dbConn.prepareStatement(
                    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50");
            } catch (Exception e) {
                e.printStackTrace();
            }
        }

        Router router = Router.router(vertx);

        // Body handler for POST requests — 25MB limit, no disk writes
        router.post().handler(BodyHandler.create()
            .setHandleFileUploads(false)
            .setBodyLimit(25 * 1024 * 1024));

        // Routes
        router.get("/pipeline").handler(this::handlePipeline);
        router.get("/baseline11").handler(this::handleBaselineGet);
        router.post("/baseline11").handler(this::handleBaselinePost);
        router.get("/baseline2").handler(this::handleBaseline2);
        router.get("/json").handler(this::handleJson);
        router.get("/compression").handler(this::handleCompression);
        router.post("/upload").handler(this::handleUpload);
        router.get("/db").handler(this::handleDb);
        router.get("/static/:filename").handler(this::handleStatic);

        // Catch-all: return 404 for unmatched routes
        router.route().handler(ctx -> ctx.response().setStatusCode(404).end());

        // HTTP/1.1 on port 8080
        HttpServerOptions httpOpts = new HttpServerOptions()
            .setPort(8080)
            .setHost("0.0.0.0")
            .setTcpNoDelay(true)
            .setTcpFastOpen(true)
            .setCompressionSupported(false)  // We handle compression manually for /compression
            .setIdleTimeout(0);

        vertx.createHttpServer(httpOpts)
            .requestHandler(router)
            .listen()
            .compose(http -> {
                // HTTP/2 + TLS on port 8443 (if certs exist)
                File cert = new File("/certs/server.crt");
                File key = new File("/certs/server.key");
                if (cert.exists() && key.exists()) {
                    HttpServerOptions httpsOpts = new HttpServerOptions()
                        .setPort(8443)
                        .setHost("0.0.0.0")
                        .setSsl(true)
                        .setUseAlpn(true)
                        .setKeyCertOptions(new PemKeyCertOptions()
                            .setCertPath("/certs/server.crt")
                            .setKeyPath("/certs/server.key"))
                        .setTcpNoDelay(true)
                        .setTcpFastOpen(true)
                        .setCompressionSupported(false)
                        .setIdleTimeout(0);

                    return vertx.createHttpServer(httpsOpts)
                        .requestHandler(router)
                        .listen();
                }
                return Future.succeededFuture();
            })
            .onSuccess(v -> startPromise.complete())
            .onFailure(startPromise::fail);
    }

    private void handlePipeline(RoutingContext ctx) {
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(OK_BUFFER);
    }

    private void handleBaselineGet(RoutingContext ctx) {
        int sum = sumParams(ctx);
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(String.valueOf(sum));
    }

    private void handleBaselinePost(RoutingContext ctx) {
        int sum = sumParams(ctx);
        String body = ctx.body().asString();
        if (body != null && !body.isEmpty()) {
            try {
                sum += Integer.parseInt(body.trim());
            } catch (NumberFormatException ignored) {}
        }
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(String.valueOf(sum));
    }

    private void handleBaseline2(RoutingContext ctx) {
        int sum = sumParams(ctx);
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(String.valueOf(sum));
    }

    private void handleJson(RoutingContext ctx) {
        if (processedItems == null) {
            ctx.response().setStatusCode(500).end("Dataset not loaded");
            return;
        }
        try {
            byte[] body = MAPPER.writeValueAsBytes(Map.of("items", processedItems, "count", processedItems.size()));
            ctx.response()
                .putHeader("content-type", "application/json")
                .end(Buffer.buffer(body));
        } catch (Exception e) {
            ctx.response().setStatusCode(500).end("Serialization failed");
        }
    }

    private void handleCompression(RoutingContext ctx) {
        if (largeProcessedItems == null) {
            ctx.response().setStatusCode(500).end("Large dataset not loaded");
            return;
        }
        try {
            byte[] body = MAPPER.writeValueAsBytes(Map.of("items", largeProcessedItems, "count", largeProcessedItems.size()));
            java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
            java.util.zip.GZIPOutputStream gz = new java.util.zip.GZIPOutputStream(baos);
            gz.write(body);
            gz.close();
            ctx.response()
                .putHeader("content-type", "application/json")
                .putHeader("content-encoding", "gzip")
                .end(Buffer.buffer(baos.toByteArray()));
        } catch (Exception e) {
            ctx.response().setStatusCode(500).end("Compression failed");
        }
    }

    private void handleUpload(RoutingContext ctx) {
        Buffer body = ctx.body().buffer();
        int len = body != null ? body.length() : 0;
        ctx.response()
            .putHeader("content-type", "text/plain")
            .end(String.valueOf(len));
    }

    private void handleDb(RoutingContext ctx) {
        if (dbStmt == null) {
            ctx.response().setStatusCode(500).end("DB not available");
            return;
        }
        // DB is blocking — execute on worker thread
        vertx.executeBlocking(() -> {
            double minPrice = 10.0, maxPrice = 50.0;
            String minParam = ctx.request().getParam("min");
            String maxParam = ctx.request().getParam("max");
            if (minParam != null) try { minPrice = Double.parseDouble(minParam); } catch (NumberFormatException ignored) {}
            if (maxParam != null) try { maxPrice = Double.parseDouble(maxParam); } catch (NumberFormatException ignored) {}

            dbStmt.setDouble(1, minPrice);
            dbStmt.setDouble(2, maxPrice);
            ResultSet rs = dbStmt.executeQuery();
            List<Map<String, Object>> items = new ArrayList<>();
            while (rs.next()) {
                List<String> tags = MAPPER.readValue(rs.getString(7), new TypeReference<>() {});
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("id", rs.getInt(1));
                row.put("name", rs.getString(2));
                row.put("category", rs.getString(3));
                row.put("price", rs.getDouble(4));
                row.put("quantity", rs.getInt(5));
                row.put("active", rs.getInt(6) == 1);
                row.put("tags", tags);
                row.put("rating", Map.of("score", rs.getDouble(8), "count", rs.getInt(9)));
                items.add(row);
            }
            rs.close();
            return MAPPER.writeValueAsBytes(Map.of("items", items, "count", items.size()));
        }).onSuccess(bytes -> {
            ctx.response()
                .putHeader("content-type", "application/json")
                .end(Buffer.buffer(bytes));
        }).onFailure(err -> {
            ctx.response().setStatusCode(500).end(err.getMessage());
        });
    }

    private void handleStatic(RoutingContext ctx) {
        String filename = ctx.pathParam("filename");
        byte[] data = staticFiles.get(filename);
        if (data == null) {
            ctx.response().setStatusCode(404).end();
            return;
        }
        int dot = filename.lastIndexOf('.');
        String ext = dot >= 0 ? filename.substring(dot) : "";
        String ct = MIME_TYPES.getOrDefault(ext, "application/octet-stream");
        ctx.response()
            .putHeader("content-type", ct)
            .end(Buffer.buffer(data));
    }

    private int sumParams(RoutingContext ctx) {
        int sum = 0;
        String a = ctx.request().getParam("a");
        String b = ctx.request().getParam("b");
        if (a != null) try { sum += Integer.parseInt(a); } catch (NumberFormatException ignored) {}
        if (b != null) try { sum += Integer.parseInt(b); } catch (NumberFormatException ignored) {}
        return sum;
    }
}
