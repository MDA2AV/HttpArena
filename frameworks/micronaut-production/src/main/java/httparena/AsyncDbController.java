package httparena;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;

import io.micronaut.core.annotation.Nullable;
import io.micronaut.core.type.Argument;
import io.micronaut.http.MediaType;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.QueryValue;
import io.micronaut.serde.ObjectMapper;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;
import jakarta.inject.Singleton;

/** GET /async-db: a range query on the items table through the asynchronous Vert.x PostgreSQL client. */
@Controller("/async-db")
@Singleton
public class AsyncDbController {

    private static final ItemList EMPTY = new ItemList(List.of(), 0);
    private static final Argument<List<String>> TAGS = Argument.listOf(String.class);
    // Keep JSON decoding in Micronaut Serialization instead of the driver's JSONB codec.
    private static final String QUERY = "SELECT id, name, category, price, quantity, active, tags::text AS tags, rating_score, rating_count"
            + " FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";

    private final Pool pool;
    private final ObjectMapper jsonMapper;

    AsyncDbController(Database database, ObjectMapper jsonMapper) {
        this.pool = database.pool();
        this.jsonMapper = jsonMapper;
    }

    @Get(produces = MediaType.APPLICATION_JSON)
    public CompletableFuture<ItemList> query(@QueryValue @Nullable String min, @QueryValue @Nullable String max,
                                           @QueryValue @Nullable String limit) {
        if (pool == null) {
            return CompletableFuture.completedFuture(EMPTY);
        }
        int lo = parse(min, 10);
        int hi = parse(max, 50);
        int lim = Math.max(1, Math.min(50, parse(limit, 50)));
        CompletableFuture<ItemList> result = new CompletableFuture<>();
        pool.preparedQuery(QUERY).execute(Tuple.of(lo, hi, lim)).onComplete(ar -> {
            if (ar.failed()) {
                result.complete(EMPTY);
                return;
            }
            try {
                List<Item> items = new ArrayList<>(ar.result().size());
                for (Row row : ar.result()) {
                    List<String> tags = jsonMapper.readValue(row.getString("tags"), TAGS);
                    items.add(new Item(row.getLong("id"), row.getString("name"), row.getString("category"),
                            row.getLong("price"), row.getLong("quantity"), row.getBoolean("active"), tags,
                            new Rating(row.getLong("rating_score"), row.getLong("rating_count"))));
                }
                result.complete(new ItemList(items, items.size()));
            } catch (IOException | RuntimeException e) {
                result.completeExceptionally(e);
            }
        });
        return result;
    }

    private static int parse(@Nullable String value, int fallback) {
        if (value == null) {
            return fallback;
        }
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
