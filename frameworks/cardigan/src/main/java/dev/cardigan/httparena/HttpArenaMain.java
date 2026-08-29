// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.core.CardiganServer;
import dev.cardigan.core.ProtocolMode;
import dev.cardigan.tls.TlsConfig;

import java.nio.file.Path;

/** Dedicated launcher for the independently scored HttpArena transports. */
public final class HttpArenaMain {
    private HttpArenaMain() {
    }

    public static void main(String[] args) throws Exception {
        String mode = args.length == 0
            ? System.getenv().getOrDefault(
                "CARDIGAN_HTTPARENA_MODE", "h1")
            : args[0];
        int threads = Integer.parseInt(
            System.getenv().getOrDefault(
                "CARDIGAN_THREADS",
                Integer.toString(
                    Runtime.getRuntime().availableProcessors())));
        System.setProperty(
            "jdk.virtualThreadScheduler.parallelism",
            Integer.toString(threads));
        System.setProperty(
            "jdk.virtualThreadScheduler.maxPoolSize",
            Integer.toString(threads));
        if (mode.equals("h1")) {
            // Cardigan owns transport I/O for these profiles. One JDK read
            // poller keeps handler socket I/O ready without adding a
            // sub-poller for every server CPU.
            System.setProperty("jdk.readPollers", "1");
        }

        int port = switch (mode) {
            case "h1", "grpc" -> 8080;
            case "json-tls" -> 8081;
            case "h2c" -> 8082;
            case "h2", "grpc-tls" -> 8443;
            default -> throw new IllegalArgumentException(
                "Unknown HttpArena mode: " + mode);
        };
        Path certificate = environmentPath(
            "CARDIGAN_CERTIFICATE", "/certs/server.crt");
        Path privateKey = environmentPath(
            "CARDIGAN_PRIVATE_KEY", "/certs/server.key");
        boolean tlsMode = mode.equals("json-tls")
            || mode.equals("h2") || mode.equals("grpc-tls");
        TlsConfig tls = tlsMode
            ? new TlsConfig(certificate, privateKey)
            : null;
        ProtocolMode protocol = switch (mode) {
            case "h2", "h2c", "grpc", "grpc-tls" ->
                ProtocolMode.HTTP2_ONLY;
            case "h1", "json-tls" -> ProtocolMode.HTTP1_ONLY;
            default -> throw new AssertionError(mode);
        };

        CardiganServer.Builder builder = CardiganServer.builder()
            .port(port)
            .eventLoops(threads)
            .protocol(protocol)
            .routes(new HttpArenaController());
        if (tls == null) {
            builder.plaintext();
        } else {
            builder.tls(tls);
        }
        if (mode.equals("json-tls")) {
            builder.routes(new HttpArenaJsonController(
                HttpArenaDataset.load(environmentPath(
                    "CARDIGAN_DATASET", "/data/dataset.json"))));
        } else if (mode.equals("h2")) {
            builder.routes(new HttpArenaStaticController(
                environmentPath(
                    "CARDIGAN_STATIC_DIR", "/data/static")));
        } else if (mode.equals("grpc") || mode.equals("grpc-tls")) {
            builder.routes(new HttpArenaGrpcController());
        }

        CardiganServer plaintext = mode.equals("json-tls")
            ? CardiganServer.builder()
                .port(8080)
                .eventLoops(1)
                .protocol(ProtocolMode.HTTP1_ONLY)
                .plaintext()
                .routes(new HttpArenaController())
                .build()
            : null;
        try (plaintext; CardiganServer server = builder.build()) {
            Runtime.getRuntime().addShutdownHook(
                Thread.ofPlatform()
                    .name("cardigan-httparena-shutdown")
                    .unstarted(() -> {
                        server.close();
                        if (plaintext != null) plaintext.close();
                    }));
            server.start();
            System.out.println(
                "Cardigan HttpArena mode " + mode
                    + " is listening on " + port);
            if (plaintext != null) {
                plaintext.start();
                System.out.println(
                    "Cardigan HttpArena baseline readiness is listening"
                        + " on 8080");
            }
            Thread.currentThread().join();
        }
    }

    private static Path environmentPath(String name, String fallback) {
        return Path.of(System.getenv().getOrDefault(name, fallback));
    }
}
