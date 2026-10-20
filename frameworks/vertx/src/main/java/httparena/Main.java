package httparena;

import httparena.JsonDtos.Item;

import java.nio.file.Files;
import java.nio.file.Path;

import io.vertx.core.DeploymentOptions;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.json.Json;

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

        // Netty's epoll transport rather than the JDK's NIO selector. Exit if it fails to
        // load, so a run can never quietly fall back to NIO.
        Vertx vertx = Vertx.vertx(new VertxOptions().setPreferNativeTransport(true));
        if (!vertx.isNativeTransportEnabled()) {
            System.err.println("epoll native transport unavailable: " + vertx.unavailableNativeTransportCause());
            System.exit(1);
        }
        Item[] items = dataset;
        int instances = Runtime.getRuntime().availableProcessors();
        vertx.deployVerticle(() -> new ServerVerticle(items), new DeploymentOptions().setInstances(instances));
    }
}
