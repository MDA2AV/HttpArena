package httparena;

import com.alibaba.fastjson2.JSON;
import com.teamzemo.aegon.AegonServer;
import com.teamzemo.aegon.ServerConfig;
import com.teamzemo.aegon.http.Context;
import com.teamzemo.aegon.http.Router;
import com.teamzemo.aegon.middleware.CompressConfig;
import httparena.model.DatasetItem;
import httparena.model.JsonPayload;
import httparena.model.ProcessedItem;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class Main {

    private static List<DatasetItem> dataset = Collections.emptyList();

    public static void main(String[] args) {
        loadDataset();

        int threads = getCpuCount();
        boolean lowMem = isLowMemlock();

        ServerConfig config = ServerConfig.builder()
                .ringEntries(lowMem ? 256 : 2048)
                .bufferPoolEntries(lowMem ? 256 : 512)
                .tcpNoDelay(true)
                .enableHttp3(true)
                .build();

        Router router = Router.create();
        registerRoutes(router);

        AegonServer server = AegonServer.create(router, config);

        // Port 8080: Plaintext HTTP/1.1 (baseline, async, latency, pipelined, limited-conn, echo-ws)
        server.listen(8080);

        // Port 8082: HTTP/2 cleartext prior knowledge (baseline-h2c, json-h2c)
        server.listen(8082);

        String certFile = "/certs/server.crt";
        String keyFile = "/certs/server.key";
        boolean hasCerts = Files.exists(Path.of(certFile)) && Files.exists(Path.of(keyFile));

        if (hasCerts) {
            server.enableTls(certFile, keyFile);
            // Port 8081: TLS HTTP/1.1 (json-tls, 8gbit, static-tls)
            server.listenTls(8081);
            // Port 8443: TLS HTTP/2 & HTTP/3 (baseline-h2, static-h2, baseline-h3, static-h3)
            server.listenTls(8443);
        }

        System.out.println("[aegon-java] Starting server on " + threads + " thread(s) (lowMem=" + lowMem + ", TLS=" + hasCerts + ")");
        server.run(threads);
    }

    private static void registerRoutes(Router router) {
        // 1. Pipeline endpoint
        router.get("/pipeline", ctx -> ctx.res().text("ok"));

        // 2. Baseline endpoints (HTTP/1.1)
        router.get("/baseline11", Main::handleBaselineGet);
        router.post("/baseline11", Main::handleBaselinePost);

        // 3. Baseline endpoints (HTTP/2)
        router.get("/baseline2", Main::handleBaselineGet);
        router.post("/baseline2", Main::handleBaselinePost);

        // 4. Async delay endpoint (Project Loom Virtual Threads)
        router.getAsync("/delay/:ms", Main::handleDelay);

        // 5. Response compression middleware & JSON endpoints
        router.useCompress(CompressConfig.defaults());
        router.get("/json/:count", Main::handleJson);

        // 6. Echo endpoint (8gbit)
        router.post("/echo", ctx -> {
            ctx.res().header("Content-Type", "application/octet-stream");
            byte[] body = ctx.req().bodyBytes();
            ctx.res().body(body != null ? body : new byte[0]);
        });

        // 7. Static file serving (static-tls, static-h2, static-h3)
        String staticDir = Files.exists(Path.of("/data/static")) ? "/data/static" : "data/static";
        if (Files.exists(Path.of(staticDir))) {
            router.staticFiles("/static", Path.of(staticDir).toAbsolutePath().toString());
        }

        // 8. WebSocket echo endpoint (RFC 6455)
        router.wsEcho("/ws");
    }

    private static void handleBaselineGet(Context ctx) {
        long a = ctx.req().queryInt("a", 0);
        long b = ctx.req().queryInt("b", 0);
        ctx.res().text(Long.toString(a + b));
    }

    private static void handleBaselinePost(Context ctx) {
        long sum = ctx.req().queryInt("a", 0) + ctx.req().queryInt("b", 0);
        String body = ctx.req().body();
        if (body != null) {
            String trimmed = body.trim();
            if (!trimmed.isEmpty()) {
                try {
                    sum += Long.parseLong(trimmed);
                } catch (NumberFormatException ignored) {}
            }
        }
        ctx.res().text(Long.toString(sum));
    }

    private static void handleDelay(Context ctx) {
        long ms = 0;
        String msParam = ctx.req().param("ms").orElse(null);
        if (msParam != null) {
            try {
                ms = Long.parseLong(msParam);
            } catch (NumberFormatException ignored) {}
        }
        if (ms > 0) {
            try {
                Thread.sleep(ms);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        ctx.res().text(Long.toString(ms));
    }

    private static void handleJson(Context ctx) {
        int count = 0;
        String countParam = ctx.req().param("count").orElse(null);
        if (countParam != null) {
            try {
                count = Integer.parseInt(countParam);
            } catch (NumberFormatException ignored) {}
        }
        long m = ctx.req().queryInt("m", 1);

        int n = Math.min(count, dataset.size());
        List<ProcessedItem> items = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            items.add(new ProcessedItem(dataset.get(i), m));
        }

        byte[] jsonBytes = JSON.toJSONBytes(new JsonPayload(n, items));
        ctx.res().header("Content-Type", "application/json").body(jsonBytes);
    }

    private static void loadDataset() {
        List<Path> paths = List.of(
                Path.of("/data/dataset.json"),
                Path.of("data/dataset.json"),
                Path.of("../data/dataset.json"),
                Path.of("../../data/dataset.json")
        );

        for (Path p : paths) {
            if (Files.exists(p)) {
                try {
                    String content = Files.readString(p);
                    dataset = JSON.parseArray(content, DatasetItem.class);
                    System.out.println("[aegon-java] Loaded dataset with " + dataset.size() + " items from " + p);
                    return;
                } catch (IOException e) {
                    System.err.println("[aegon-java] Failed to read " + p + ": " + e.getMessage());
                }
            }
        }
        System.err.println("[aegon-java] Warning: Could not find dataset.json");
    }

    private static int getCpuCount() {
        int quotaLimit = 0;

        // 1. cgroup v2
        Path cpuMax = Path.of("/sys/fs/cgroup/cpu.max");
        if (Files.exists(cpuMax)) {
            try {
                String content = Files.readString(cpuMax).trim();
                String[] parts = content.split("\\s+");
                if (parts.length >= 2 && !parts[0].equals("max")) {
                    long q = Long.parseLong(parts[0]);
                    long p = Long.parseLong(parts[1]);
                    if (p > 0 && q > 0) {
                        quotaLimit = (int) (q / p);
                    }
                }
            } catch (Exception ignored) {}
        }

        // 2. cgroup v1
        if (quotaLimit == 0) {
            Path cfsQuota = Path.of("/sys/fs/cgroup/cpu/cpu.cfs_quota_us");
            Path cfsPeriod = Path.of("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
            if (Files.exists(cfsQuota) && Files.exists(cfsPeriod)) {
                try {
                    long q = Long.parseLong(Files.readString(cfsQuota).trim());
                    long p = Long.parseLong(Files.readString(cfsPeriod).trim());
                    if (q > 0 && p > 0) {
                        quotaLimit = (int) (q / p);
                    }
                } catch (Exception ignored) {}
            }
        }

        int hw = Runtime.getRuntime().availableProcessors();
        int effective = hw;
        if (quotaLimit > 0 && quotaLimit < effective) {
            effective = quotaLimit;
        }
        return Math.max(1, effective);
    }

    private static boolean isLowMemlock() {
        try {
            Path limits = Path.of("/proc/self/limits");
            if (Files.exists(limits)) {
                for (String line : Files.readAllLines(limits)) {
                    if (line.startsWith("Max locked memory")) {
                        String[] parts = line.split("\\s+");
                        if (parts.length >= 4 && !parts[3].equalsIgnoreCase("unlimited")) {
                            long val = Long.parseLong(parts[3]);
                            if (val < 64 * 1024 * 1024) {
                                return true;
                            }
                        }
                    }
                }
            }
        } catch (Exception ignored) {}
        return false;
    }
}
