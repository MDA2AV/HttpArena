package com.httparena;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

import io.helidon.common.GenericType;
import io.helidon.json.binding.JsonBinding;
import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static io.helidon.http.HeaderValues.CONTENT_TYPE_JSON;

class JsonHandler implements Handler {
    private final List<Item> jsonDataset;

    JsonHandler(String dataLocation) throws IOException {
        this.jsonDataset = loadJsonDataset(dataLocation);
    }

    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        res.header(CONTENT_TYPE_JSON);

        int requestedCount = req.path().pathParameters().first("count")
                .asInt()
                .orElse(jsonDataset.size());
        int multiplier = req.query().first("m")
                .map(Integer::parseInt)
                .orElse(1);
        int count = Math.min(Math.max(requestedCount, 0), jsonDataset.size());

        List<TotalItem> totalItems = jsonDataset.subList(0, count).stream()
                .map(item -> TotalItem.create(item, multiplier))
                .toList();
        res.send(new TotalItems(totalItems, totalItems.size()));
    }

    private static List<Item> loadJsonDataset(String dataLocation) throws IOException {
        // Dataset
        String path = System.getenv("DATASET_PATH");
        if (path == null) {
            path = dataLocation + "/dataset.json";
        }
        Path datasetPath = Paths.get(path);
        if (!Files.exists(datasetPath)) {
            throw new IllegalArgumentException("Failed to load JSON dataset from: " + datasetPath.toAbsolutePath().normalize());
        }

        return JsonBinding.create()
                .deserialize(Files.readAllBytes(datasetPath), new GenericType<List<Item>>() { });
    }
}
