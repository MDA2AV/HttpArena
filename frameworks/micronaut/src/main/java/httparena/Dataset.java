package httparena;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import io.micronaut.core.type.Argument;
import io.micronaut.json.JsonMapper;

import jakarta.inject.Singleton;

/**
 * The dataset, read once at startup from DATASET_PATH or /data/dataset.json.
 * A missing or unreadable file leaves the list empty, the server still starts.
 */
@Singleton
public class Dataset {

    private final List<Item> items;

    Dataset(JsonMapper jsonMapper) {
        String path = System.getenv().getOrDefault("DATASET_PATH", "/data/dataset.json");
        List<Item> loaded = List.of();
        try {
            byte[] raw = Files.readAllBytes(Path.of(path));
            loaded = jsonMapper.readValue(raw, Argument.listOf(Item.class));
        } catch (Exception ignored) {
            // no dataset, serve an empty list
        }
        this.items = List.copyOf(loaded);
    }

    public List<Item> items() {
        return items;
    }
}
