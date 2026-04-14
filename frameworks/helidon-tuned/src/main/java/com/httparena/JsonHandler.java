package com.httparena;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.io.ByteArrayOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.Locale;
import java.util.zip.GZIPOutputStream;

import io.helidon.common.GenericType;
import io.helidon.http.Header;
import io.helidon.http.HeaderNames;
import io.helidon.http.HeaderValues;
import io.helidon.json.binding.JsonBinding;
import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static com.httparena.Main.SERVER_HEADER;
import static io.helidon.http.HeaderValues.CONTENT_TYPE_JSON;

class JsonHandler implements Handler {
    private static final JsonBinding JSON_BINDING = JsonBinding.create();
    private static final Header VARY_ACCEPT_ENCODING =
            HeaderValues.createCached(HeaderNames.VARY, HeaderNames.ACCEPT_ENCODING_NAME);
    private static final Header CONTENT_ENCODING_GZIP =
            HeaderValues.createCached(HeaderNames.CONTENT_ENCODING, "gzip");

    private final List<Item> jsonDataset;

    JsonHandler(String dataLocation) throws IOException {
        this.jsonDataset = loadJsonDataset(dataLocation);
    }

    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        res.header(SERVER_HEADER);
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
        byte[] responseBody = JSON_BINDING.serializeToBytes(new TotalItems(totalItems, totalItems.size()));
        String acceptEncoding = req.headers()
                .first(HeaderNames.ACCEPT_ENCODING)
                .orElse("")
                .toLowerCase(Locale.ROOT);
        res.header(VARY_ACCEPT_ENCODING);
        if (acceptEncoding.contains("gzip")) {
            res.header(CONTENT_ENCODING_GZIP);
            res.send(gzip(responseBody));
            return;
        }
        res.send(responseBody);
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

        return JSON_BINDING.deserialize(Files.readAllBytes(datasetPath), new GenericType<List<Item>>() { });
    }

    private static byte[] gzip(byte[] bytes) {
        try {
            ByteArrayOutputStream baos = new ByteArrayOutputStream(bytes.length);
            try (GZIPOutputStream gzip = new GZIPOutputStream(baos)) {
                gzip.write(bytes);
            }
            return baos.toByteArray();
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to gzip JSON response", e);
        }
    }
}
