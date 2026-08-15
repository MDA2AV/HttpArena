package httparena;

import java.util.Map;

import io.vertx.core.Future;
import io.vertx.core.VerticleBase;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.core.http.HttpServerRequest;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.handler.BodyHandler;

public class ServerVerticle extends VerticleBase {

    private static final long MAX_BODY = 25L * 1024 * 1024;

    private final JsonArray dataset;

    public ServerVerticle(JsonArray dataset) {
        this.dataset = dataset;
    }

    @Override
    public Future<?> start() {
        Router router = Router.router(vertx);

        router.get("/pipeline").handler(ctx -> text(ctx, "ok"));
        router.get("/baseline11").handler(this::baselineGet);
        router.post("/baseline11")
                .handler(BodyHandler.create().setBodyLimit(MAX_BODY))
                .handler(this::baselinePost);
        router.get("/json/:count").handler(this::jsonItems);
        router.post("/upload").handler(this::upload);

        HttpServerOptions options = new HttpServerOptions()
                .setHost("0.0.0.0")
                .setPort(8080)
                .setCompressionSupported(true);

        return vertx.createHttpServer(options).requestHandler(router).listen();
    }

    private void text(RoutingContext ctx, String body) {
        ctx.response().putHeader("content-type", "text/plain").end(body);
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

    private void upload(RoutingContext ctx) {
        HttpServerRequest request = ctx.request();
        long[] size = {0};
        request.handler(buffer -> size[0] += buffer.length());
        request.endHandler(v -> text(ctx, Long.toString(size[0])));
        request.resume();
    }
}
