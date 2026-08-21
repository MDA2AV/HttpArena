package httparena;

import java.io.File;
import java.util.List;
import java.util.Map;

import io.vertx.core.Future;
import io.vertx.core.VerticleBase;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.core.http.HttpServerRequest;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.core.net.PemKeyCertOptions;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.handler.BodyHandler;
import io.vertx.pgclient.PgBuilder;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.redis.client.Redis;
import io.vertx.redis.client.RedisAPI;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.PoolOptions;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

public class ServerVerticle extends VerticleBase {

    private static final long MAX_BODY = 25L * 1024 * 1024;
    private static final String STATIC_ROOT = "/data/static";
    private static final String CERT = "/certs/server.crt";
    private static final String KEY = "/certs/server.key";

    private static final String ITEM_COLUMNS =
            "id, name, category, price, quantity, active, tags, rating_score, rating_count";

    // The profile reads and writes the same ids, so a long TTL would answer from a copy
    // the writes have already moved past.
    private static final String CRUD_TTL_MS = "200";

    private final JsonArray dataset;

    private Pool pgPool;
    private RedisAPI redis;

    public ServerVerticle(JsonArray dataset) {
        this.dataset = dataset;
    }

    @Override
    public Future<?> start() {
        String dbUrl = System.getenv("DATABASE_URL");
        if (dbUrl != null && !dbUrl.isEmpty()) {
            // The pool is per verticle instance and one is deployed per core, so the
            // harness's connection budget is split across them rather than opened by each.
            pgPool = PgBuilder.pool()
                    .connectingTo(PgConnectOptions.fromUri(dbUrl))
                    .with(new PoolOptions().setMaxSize(4))
                    .using(vertx)
                    .build();
        }
        String redisUrl = System.getenv("REDIS_URL");
        if (redisUrl != null && !redisUrl.isEmpty()) {
            redis = RedisAPI.api(Redis.createClient(vertx, redisUrl));
        }
        Router router = Router.router(vertx);

        router.get("/pipeline").handler(ctx -> text(ctx, "ok"));
        router.get("/baseline2").handler(this::baselineGet);
        router.get("/baseline11").handler(this::baselineGet);
        router.post("/baseline11")
                .handler(BodyHandler.create().setBodyLimit(MAX_BODY))
                .handler(this::baselinePost);
        router.get("/json/:count").handler(this::jsonItems);
        router.get("/async-db").handler(this::asyncDb);
        router.get("/static/:filename").handler(this::staticFile);
        router.get("/crud/items").handler(this::crudList);
        router.post("/crud/items")
                .handler(BodyHandler.create())
                .handler(this::crudCreate);
        router.get("/crud/items/:id").handler(this::crudRead);
        router.put("/crud/items/:id")
                .handler(BodyHandler.create())
                .handler(this::crudUpdate);
        router.post("/upload").handler(this::upload);

        HttpServerOptions options = new HttpServerOptions()
                .setHost("0.0.0.0")
                .setPort(8080)
                .setCompressionSupported(true);

        Future<?> plain = vertx.createHttpServer(options).requestHandler(router).listen();

        // json-tls and static-tls on 8081, the same router behind TLS. This verticle is
        // deployed once per core, so every instance binds both ports and the listener is
        // spread across all the event loops rather than parked on one. ALPN is off: the
        // two profiles want HTTP/1.1 negotiated and no h2 offered. The harness only mounts
        // /certs for the TLS profiles.
        if (new File(CERT).isFile() && new File(KEY).isFile()) {
            HttpServerOptions tls = new HttpServerOptions()
                    .setHost("0.0.0.0")
                    .setPort(8081)
                    .setCompressionSupported(true)
                    .setSsl(true)
                    .setUseAlpn(false)
                    .setKeyCertOptions(new PemKeyCertOptions().setCertPath(CERT).setKeyPath(KEY));
            return Future.all(plain, vertx.createHttpServer(tls).requestHandler(router).listen());
        }
        return plain;
    }

    private void text(RoutingContext ctx, String body) {
        ctx.response().putHeader("content-type", "text/plain").end(body);
    }

    private void json(RoutingContext ctx, String body) {
        ctx.response().putHeader("content-type", "application/json").end(body);
    }

    private void dbError(RoutingContext ctx, String message, int status) {
        ctx.response().setStatusCode(status)
                .putHeader("content-type", "application/json")
                .end("{\"error\":\"" + message + "\"}");
    }

    private long querySum(RoutingContext ctx) {
        long sum = 0;
        for (Map.Entry<String, String> entry : ctx.queryParams()) {
            try {
                sum += Long.parseLong(entry.getValue().trim());
            } catch (NumberFormatException ignored) {
            }
        }
        return sum;
    }

    private int intParam(RoutingContext ctx, String name, int fallback) {
        String raw = ctx.queryParams().get(name);
        if (raw == null) return fallback;
        try {
            return Integer.parseInt(raw.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private void baselineGet(RoutingContext ctx) {
        text(ctx, Long.toString(querySum(ctx)));
    }

    private void baselinePost(RoutingContext ctx) {
        long sum = querySum(ctx);
        String body = ctx.body().asString();
        if (body != null) {
            try {
                sum += Long.parseLong(body.trim());
            } catch (NumberFormatException ignored) {
            }
        }
        text(ctx, Long.toString(sum));
    }

    private void jsonItems(RoutingContext ctx) {
        int count;
        try {
            count = Integer.parseInt(ctx.pathParam("count"));
        } catch (NumberFormatException e) {
            count = 0;
        }
        count = Math.max(0, Math.min(count, dataset.size()));

        long m = 1;
        String multiplier = ctx.queryParams().get("m");
        if (multiplier != null) {
            try {
                m = Long.parseLong(multiplier);
            } catch (NumberFormatException ignored) {
            }
        }

        JsonArray items = new JsonArray();
        for (int i = 0; i < count; i++) {
            JsonObject item = dataset.getJsonObject(i).copy();
            item.put("total", item.getLong("price") * item.getLong("quantity") * m);
            items.add(item);
        }
        ctx.json(new JsonObject().put("items", items).put("count", count));
    }

    // tags is a JSONB column, so the client hands back a JsonArray rather than text.
    private JsonArray tags(Row row) {
        Object value = row.getValue("tags");
        if (value instanceof JsonArray array) return array;
        if (value instanceof String text) return new JsonArray(text);
        return new JsonArray();
    }

    private JsonObject itemShape(Row row) {
        return new JsonObject()
                .put("id", row.getLong("id"))
                .put("name", row.getString("name"))
                .put("category", row.getString("category"))
                .put("price", row.getLong("price"))
                .put("quantity", row.getLong("quantity"))
                .put("active", row.getBoolean("active"))
                .put("tags", tags(row))
                .put("rating", new JsonObject()
                        .put("score", row.getLong("rating_score"))
                        .put("count", row.getLong("rating_count")));
    }

    private void asyncDb(RoutingContext ctx) {
        if (pgPool == null) {
            json(ctx, "{\"items\":[],\"count\":0}");
            return;
        }
        int min = intParam(ctx, "min", 10);
        int max = intParam(ctx, "max", 50);
        int limit = Math.max(1, Math.min(50, intParam(ctx, "limit", 50)));

        pgPool.preparedQuery("SELECT " + ITEM_COLUMNS + " FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3")
                .execute(Tuple.of(min, max, limit))
                .onSuccess(rows -> {
                    JsonArray items = new JsonArray();
                    for (Row row : rows) items.add(itemShape(row));
                    json(ctx, new JsonObject().put("items", items).put("count", items.size()).encode());
                })
                .onFailure(e -> json(ctx, "{\"items\":[],\"count\":0}"));
    }

    // Standard mode still reads static bodies from disk on every request: sendFile hands
    // the descriptor to the kernel rather than holding the bytes. The pre-compressed
    // sibling is picked per request and is also read from disk.
    private void staticFile(RoutingContext ctx) {
        String filename = ctx.pathParam("filename");
        if (filename == null || filename.contains("/") || filename.contains("..")) {
            ctx.response().setStatusCode(404).end();
            return;
        }
        String path = STATIC_ROOT + "/" + filename;
        if (!new File(path).isFile()) {
            ctx.response().setStatusCode(404).end();
            return;
        }
        ctx.response().putHeader("content-type", contentType(filename));

        String accept = ctx.request().getHeader("accept-encoding");
        if (accept != null) {
            if (accept.contains("br") && new File(path + ".br").isFile()) {
                ctx.response().putHeader("content-encoding", "br").sendFile(path + ".br");
                return;
            }
            if (accept.contains("gzip") && new File(path + ".gz").isFile()) {
                ctx.response().putHeader("content-encoding", "gzip").sendFile(path + ".gz");
                return;
            }
        }
        ctx.response().sendFile(path);
    }

    private String contentType(String filename) {
        int dot = filename.lastIndexOf('.');
        String ext = dot < 0 ? "" : filename.substring(dot);
        return switch (ext) {
            case ".css" -> "text/css";
            case ".js" -> "application/javascript";
            case ".html" -> "text/html";
            case ".woff2" -> "font/woff2";
            case ".svg" -> "image/svg+xml";
            case ".webp" -> "image/webp";
            case ".json" -> "application/json";
            default -> "application/octet-stream";
        };
    }

    private void crudList(RoutingContext ctx) {
        if (pgPool == null) {
            dbError(ctx, "DB not available", 500);
            return;
        }
        String category = ctx.queryParams().get("category");
        if (category == null) category = "electronics";
        int page = Math.max(1, intParam(ctx, "page", 1));
        int limit = Math.max(1, Math.min(50, intParam(ctx, "limit", 10)));

        pgPool.preparedQuery("SELECT " + ITEM_COLUMNS + " FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3")
                .execute(Tuple.of(category, limit, (page - 1) * limit))
                .onSuccess(rows -> {
                    JsonArray items = new JsonArray();
                    for (Row row : rows) items.add(itemShape(row));
                    json(ctx, new JsonObject()
                            .put("items", items)
                            .put("total", items.size())
                            .put("page", page)
                            .put("limit", limit)
                            .encode());
                })
                .onFailure(e -> dbError(ctx, "query failed", 500));
    }

    private void crudCreate(RoutingContext ctx) {
        if (pgPool == null) {
            dbError(ctx, "DB not available", 500);
            return;
        }
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) {
            dbError(ctx, "insert failed", 500);
            return;
        }
        pgPool.preparedQuery("INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) "
                        + "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) "
                        + "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id")
                .execute(Tuple.of(
                        body.getLong("id"),
                        body.getString("name", "New Product"),
                        body.getString("category", "test"),
                        body.getLong("price", 0L),
                        body.getLong("quantity", 0L)))
                .onSuccess(rows -> ctx.response().setStatusCode(201)
                        .putHeader("content-type", "application/json")
                        .end(new JsonObject()
                                .put("id", rows.iterator().next().getLong("id"))
                                .put("name", body.getValue("name"))
                                .put("category", body.getValue("category"))
                                .put("price", body.getValue("price"))
                                .put("quantity", body.getValue("quantity"))
                                .encode()))
                .onFailure(e -> dbError(ctx, "insert failed", 500));
    }

    // Cache-aside on Redis where the harness provides it - crud is the one profile that
    // does, and the cache is shared across every verticle instance.
    private void crudRead(RoutingContext ctx) {
        if (pgPool == null) {
            dbError(ctx, "DB not available", 500);
            return;
        }
        long id;
        try {
            id = Long.parseLong(ctx.pathParam("id"));
        } catch (NumberFormatException e) {
            ctx.response().setStatusCode(404).end();
            return;
        }
        String key = "crud:" + id;
        if (redis == null) {
            crudReadFromDb(ctx, id, key);
            return;
        }
        redis.get(key)
                .onSuccess(hit -> {
                    if (hit != null) {
                        ctx.response()
                                .putHeader("content-type", "application/json")
                                .putHeader("x-cache", "HIT")
                                .end(hit.toString());
                    } else {
                        crudReadFromDb(ctx, id, key);
                    }
                })
                .onFailure(e -> crudReadFromDb(ctx, id, key));
    }

    private void crudReadFromDb(RoutingContext ctx, long id, String key) {
        pgPool.preparedQuery("SELECT " + ITEM_COLUMNS + " FROM items WHERE id = $1 LIMIT 1")
                .execute(Tuple.of(id))
                .onSuccess(rows -> {
                    if (rows.size() == 0) {
                        ctx.response().setStatusCode(404).end();
                        return;
                    }
                    String body = itemShape(rows.iterator().next()).encode();
                    if (redis != null) {
                        redis.set(List.of(key, body, "PX", CRUD_TTL_MS));
                    }
                    ctx.response()
                            .putHeader("content-type", "application/json")
                            .putHeader("x-cache", "MISS")
                            .end(body);
                })
                .onFailure(e -> dbError(ctx, "query failed", 500));
    }

    private void crudUpdate(RoutingContext ctx) {
        if (pgPool == null) {
            dbError(ctx, "DB not available", 500);
            return;
        }
        long id;
        try {
            id = Long.parseLong(ctx.pathParam("id"));
        } catch (NumberFormatException e) {
            ctx.response().setStatusCode(404).end();
            return;
        }
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) {
            dbError(ctx, "update failed", 500);
            return;
        }
        long finalId = id;
        pgPool.preparedQuery("UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4")
                .execute(Tuple.of(
                        body.getString("name", "Updated"),
                        body.getLong("price", 0L),
                        body.getLong("quantity", 0L),
                        id))
                .onSuccess(rows -> {
                    if (rows.rowCount() == 0) {
                        ctx.response().setStatusCode(404).end();
                        return;
                    }
                    if (redis != null) {
                        redis.del(List.of("crud:" + finalId));
                    }
                    json(ctx, new JsonObject()
                            .put("id", finalId)
                            .put("name", body.getValue("name"))
                            .put("price", body.getValue("price"))
                            .put("quantity", body.getValue("quantity"))
                            .encode());
                })
                .onFailure(e -> dbError(ctx, "update failed", 500));
    }

    private void upload(RoutingContext ctx) {
        HttpServerRequest request = ctx.request();
        long[] size = {0};
        request.handler(buffer -> size[0] += buffer.length());
        request.endHandler(v -> text(ctx, Long.toString(size[0])));
        request.resume();
    }
}
