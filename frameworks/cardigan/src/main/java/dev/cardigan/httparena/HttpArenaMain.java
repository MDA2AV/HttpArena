// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.core.CardiganServer;
import dev.cardigan.core.CardiganRuntime;
import dev.cardigan.core.ProtocolMode;
import dev.cardigan.tls.TlsConfig;

import java.nio.file.Path;

/** Launches Cardigan's HttpArena listeners in one process. */
public final class HttpArenaMain {
    private HttpArenaMain() {
    }

    public static void main(String[] args) throws Exception {
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
        // Cardigan owns transport I/O for these profiles. One JDK read poller
        // keeps handler socket I/O ready for application-side socket clients.
        System.setProperty("jdk.readPollers", "1");

        Path certificate = environmentPath(
            "CARDIGAN_CERTIFICATE", "/certs/server.crt");
        Path privateKey = environmentPath(
            "CARDIGAN_PRIVATE_KEY", "/certs/server.key");
        TlsConfig tls = new TlsConfig(certificate, privateKey);
        Path staticDirectory = environmentPath(
            "CARDIGAN_STATIC_DIR", "/data/static");
        HttpArenaDataset dataset = HttpArenaDataset.load(environmentPath(
            "CARDIGAN_DATASET", "/data/dataset.json"));

        try (CardiganRuntime runtime = CardiganRuntime.builder()
                .eventLoops(threads)
                .build()) {
            CardiganServer plaintext = CardiganServer.builder()
                .port(8080)
                .runtime(runtime)
                .protocol(ProtocolMode.HTTP1_AND_HTTP2)
                .plaintext()
                .routes(
                    new HttpArenaController(),
                    new HttpArenaGrpcController())
                .build();
            CardiganServer jsonTls = CardiganServer.builder()
                .port(8081)
                .runtime(runtime)
                .protocol(ProtocolMode.HTTP1_ONLY)
                .tls(tls)
                .routes(
                    new HttpArenaController(),
                    new HttpArenaJsonController(dataset))
                .build();
            CardiganServer h2c = CardiganServer.builder()
                .port(8082)
                .runtime(runtime)
                .protocol(ProtocolMode.HTTP2_ONLY)
                .plaintext()
                .routes(new HttpArenaController())
                .build();
            CardiganServer h2Tls = CardiganServer.builder()
                .port(8443)
                .runtime(runtime)
                .protocol(ProtocolMode.HTTP2_ONLY)
                .tls(tls)
                .routes(
                    new HttpArenaController(),
                    new HttpArenaStaticController(staticDirectory),
                    new HttpArenaGrpcController())
                .build();

            CardiganServer[] servers = {plaintext, jsonTls, h2c, h2Tls};
            try (plaintext; jsonTls; h2c; h2Tls) {
                Runtime.getRuntime().addShutdownHook(
                    Thread.ofPlatform()
                        .name("cardigan-httparena-shutdown")
                        .unstarted(() -> {
                            for (int i = servers.length - 1; i >= 0; i--) {
                                servers[i].close();
                            }
                            runtime.close();
                        }));
                for (CardiganServer server : servers) {
                    server.start();
                }
                System.out.println(
                    "Cardigan HttpArena listeners are ready on"
                        + " 8080, 8081, 8082, and 8443");
                Thread.currentThread().join();
            }
        }
    }

    private static Path environmentPath(String name, String fallback) {
        return Path.of(System.getenv().getOrDefault(name, fallback));
    }
}
