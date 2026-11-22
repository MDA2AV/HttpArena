package httparena;

import httparena.JsonDtos.Item;

import java.nio.file.Files;
import java.nio.file.Path;

import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.json.Json;
import io.vertx.core.net.OpenSSLEngineOptions;

import io.netty.handler.ssl.OpenSsl;

public class Main {

    public static void main(String[] args) throws Exception {
        String path = System.getenv().getOrDefault("DATASET_PATH", "/data/dataset.json");
        Item[] dataset = new Item[0];
        try {
            dataset = Json.decodeValue(
                Buffer.buffer(Files.readAllBytes(Path.of(path))),
                Item[].class);
        } catch (Exception ignored) {
        }

        // The TLS port runs on OpenSSL, and without it every 8081 listen fails. Exit with the
        // reason up front, the same as for epoll, rather than leave it to a failed deployment.
        if (!OpenSSLEngineOptions.isAvailable()) {
            System.err.println("OpenSSL unavailable: " + OpenSsl.unavailabilityCause());
            System.exit(1);
        }

        // One Vertx per core, each with a single event loop. A Vertx folds every server on the
        // same host:port into one listening socket, accepted on its one acceptor thread whatever
        // setReusePort says, so that thread caps the connections it can take per second. With a
        // Vertx per core, each binds its own SO_REUSEPORT socket (set in ServerVerticle) and the
        // kernel spreads new connections across them.
        Item[] items = dataset;
        int cores = Runtime.getRuntime().availableProcessors();
        VertxOptions options = new VertxOptions()
                .setPreferNativeTransport(true)
                .setEventLoopPoolSize(1);
        for (int i = 0; i < cores; i++) {
            Vertx vertx = Vertx.vertx(options);
            // Netty's epoll transport rather than the JDK's NIO selector. Exit if it fails to
            // load, so a run can never quietly fall back to NIO.
            if (!vertx.isNativeTransportEnabled()) {
                System.err.println("epoll native transport unavailable: " + vertx.unavailableNativeTransportCause());
                System.exit(1);
            }
            // A listener that fails to bind would leave this core serving nothing.
            vertx.deployVerticle(new ServerVerticle(items)).onFailure(e -> {
                e.printStackTrace();
                System.exit(1);
            });
        }
    }
}
