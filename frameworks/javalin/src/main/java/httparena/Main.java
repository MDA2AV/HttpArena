package httparena;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

import io.javalin.Javalin;
import io.javalin.compression.CompressionStrategy;
import io.javalin.http.ContentType;
import io.javalin.http.Context;
import io.javalin.json.JavalinJackson;

public final class Main {

    public static void main(String[] args) {
        List<Row> dataset = loadDataset();

        Javalin.create(config -> {
            config.jetty.host = "0.0.0.0";
            config.jetty.port = 8080;
            config.jsonMapper(new JavalinJackson());
            // standard mode: gzip is Javalin's own CompressionStrategy with its default level
            // and default minimum size, nothing hand-rolled
            config.http.compressionStrategy = CompressionStrategy.GZIP;

            config.routes.get("/pipeline", ctx -> ctx.contentType(ContentType.PLAIN).result("ok"));
            config.routes.get("/baseline11", ctx -> baseline(ctx, false));
            config.routes.post("/baseline11", ctx -> baseline(ctx, true));
            config.routes.get("/json/{count}", ctx -> json(ctx, dataset));
            config.routes.post("/upload", Main::upload);
        }).start();
    }

    // A missing or unreadable dataset serves an empty list instead of taking the server down
    private static List<Row> loadDataset() {
        String path = System.getenv().getOrDefault("DATASET_PATH", "/data/dataset.json");
        try {
            byte[] bytes = Files.readAllBytes(Path.of(path));
            return new ObjectMapper().readValue(bytes, new TypeReference<List<Row>>() {});
        } catch (Exception ignored) {
            return List.of();
        }
    }

    private static void baseline(Context ctx, boolean withBody) {
        long sum = 0;
        for (List<String> values : ctx.queryParamMap().values()) {
            for (String value : values) {
                sum += parseOrZero(value);
            }
        }
        if (withBody) {
            sum += parseOrZero(ctx.body());
        }
        ctx.contentType(ContentType.PLAIN).result(Long.toString(sum));
    }

    private static void json(Context ctx, List<Row> dataset) {
        int count;
        try {
            count = Integer.parseInt(ctx.pathParam("count"));
        } catch (NumberFormatException e) {
            count = 0;
        }
        count = Math.max(0, Math.min(count, dataset.size()));

        long m = 1;
        String multiplier = ctx.queryParam("m");
        if (multiplier != null) {
            try {
                m = Long.parseLong(multiplier);
            } catch (NumberFormatException ignored) {
            }
        }

        List<Item> items = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            Row row = dataset.get(i);
            items.add(new Item(row.id(), row.name(), row.category(), row.price(), row.quantity(),
                    row.active(), row.tags(), row.rating(), row.price() * row.quantity() * m));
        }
        // json-comp negotiation belongs to the CompressionStrategy configured above
        ctx.json(new Items(items, count));
    }

    // The body is counted off the request stream, so the 20 MB upload is never buffered
    private static void upload(Context ctx) throws Exception {
        long size = 0;
        byte[] buffer = new byte[65536];
        try (InputStream in = ctx.bodyInputStream()) {
            int read;
            while ((read = in.read(buffer)) != -1) {
                size += read;
            }
        }
        ctx.contentType(ContentType.PLAIN).result(Long.toString(size));
    }

    private static long parseOrZero(String value) {
        if (value == null) {
            return 0;
        }
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    public record Rating(long score, long count) {
    }

    public record Row(long id, String name, String category, long price, long quantity,
                      boolean active, List<String> tags, Rating rating) {
    }

    public record Item(long id, String name, String category, long price, long quantity,
                       boolean active, List<String> tags, Rating rating, long total) {
    }

    public record Items(List<Item> items, int count) {
    }
}
