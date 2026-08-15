package httparena;

import java.nio.file.Files;
import java.nio.file.Path;

import io.vertx.core.DeploymentOptions;
import io.vertx.core.Vertx;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.json.JsonArray;

public class Main {

    public static void main(String[] args) throws Exception {
        String path = System.getenv().getOrDefault("DATASET_PATH", "/data/dataset.json");
        JsonArray dataset = new JsonArray();
        try {
            dataset = new JsonArray(Buffer.buffer(Files.readAllBytes(Path.of(path))));
        } catch (Exception ignored) {
        }

        Vertx vertx = Vertx.vertx();
        JsonArray items = dataset;
        int instances = Runtime.getRuntime().availableProcessors();
        vertx.deployVerticle(() -> new ServerVerticle(items), new DeploymentOptions().setInstances(instances));
    }
}
