package httparena;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;

import io.micronaut.core.annotation.Nullable;
import io.micronaut.http.MediaType;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.QueryValue;
import io.vertx.core.json.JsonArray;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;
import jakarta.inject.Singleton;

/** GET /async-db: a range query on the items table through the asynchronous Vert.x PostgreSQL client. */
@Controller("/async-db")
@Singleton
public class AsyncDbController {

    private static final ItemList EMPTY = new ItemList(List.of(), 0);
    private static final String QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
            + " FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";

    private final Pool pool;

    AsyncDbController(Database database) {
        this.pool = database.pool();
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
            List<Item> items = new ArrayList<>(ar.result().size());
            for (Row row : ar.result()) {
                Object tags = row.getValue("tags");
                List<String> tagList = new ArrayList<>();
                if (tags instanceof JsonArray array) {
                    for (Object tag : array) {
                        tagList.add(String.valueOf(tag));
                    }
                }
                items.add(new Item(row.getLong("id"), row.getString("name"), row.getString("category"),
                        row.getLong("price"), row.getLong("quantity"), row.getBoolean("active"), tagList,
                        new Rating(row.getLong("rating_score"), row.getLong("rating_count"))));
            }
            result.complete(new ItemList(items, items.size()));
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
