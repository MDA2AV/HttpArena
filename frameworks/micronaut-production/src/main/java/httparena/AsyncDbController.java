package httparena;

import java.util.concurrent.CompletableFuture;

import io.micronaut.core.annotation.Nullable;
import io.micronaut.http.MediaType;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.QueryValue;
import io.vertx.core.Vertx;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.pgclient.PgBuilder;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.PoolOptions;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;
import jakarta.annotation.PreDestroy;
import jakarta.inject.Singleton;

/** GET /async-db: a range query on the items table through the asynchronous Vert.x PostgreSQL client. */
@Controller("/async-db")
@Singleton
public class AsyncDbController {

    private static final String EMPTY = "{\"items\":[],\"count\":0}";
    private static final String QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
            + " FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3";

    private final Vertx vertx;
    private final Pool pool;

    AsyncDbController() {
        String url = System.getenv("DATABASE_URL");
        if (url == null || url.isEmpty()) {
            vertx = null;
            pool = null;
            return;
        }
        // The harness caps the number of connections it allows; the pool is sized from that cap
        int maxConn = 256;
        String cap = System.getenv("DATABASE_MAX_CONN");
        if (cap != null && !cap.isEmpty()) {
            maxConn = Math.max(1, Integer.parseInt(cap));
        }
        vertx = Vertx.vertx();
        pool = PgBuilder.pool()
                .connectingTo(PgConnectOptions.fromUri(url))
                .with(new PoolOptions().setMaxSize(maxConn))
                .using(vertx)
                .build();
    }

    @PreDestroy
    void close() {
        if (vertx != null) {
            vertx.close();
        }
    }

    @Get(produces = MediaType.APPLICATION_JSON)
    public CompletableFuture<String> query(@QueryValue @Nullable String min, @QueryValue @Nullable String max,
                                           @QueryValue @Nullable String limit) {
        if (pool == null) {
            return CompletableFuture.completedFuture(EMPTY);
        }
        int lo = parse(min, 10);
        int hi = parse(max, 50);
        int lim = Math.max(1, Math.min(50, parse(limit, 50)));
        CompletableFuture<String> result = new CompletableFuture<>();
        pool.preparedQuery(QUERY).execute(Tuple.of(lo, hi, lim)).onComplete(ar -> {
            if (ar.failed()) {
                result.complete(EMPTY);
                return;
            }
            JsonArray items = new JsonArray();
            for (Row row : ar.result()) {
                Object tags = row.getValue("tags");
                items.add(new JsonObject()
                        .put("id", row.getLong("id"))
                        .put("name", row.getString("name"))
                        .put("category", row.getString("category"))
                        .put("price", row.getLong("price"))
                        .put("quantity", row.getLong("quantity"))
                        .put("active", row.getBoolean("active"))
                        .put("tags", tags instanceof JsonArray a ? a : tags instanceof String s ? new JsonArray(s) : new JsonArray())
                        .put("rating", new JsonObject()
                                .put("score", row.getLong("rating_score"))
                                .put("count", row.getLong("rating_count"))));
            }
            result.complete(new JsonObject().put("items", items).put("count", items.size()).encode());
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
