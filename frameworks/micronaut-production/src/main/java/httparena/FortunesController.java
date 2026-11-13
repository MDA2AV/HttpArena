package httparena;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CompletableFuture;

import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.views.rocker.RockerWritable;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.Row;

/** GET /fortunes: Micronaut Views writes the precompiled Rocker template, with HTML escaping enabled. */
@Controller("/fortunes")
public class FortunesController {

    private final Pool pool;

    FortunesController(Database database) {
        this.pool = database.pool();
    }

    public record Fortune(int id, String message) {
    }

    @Get(produces = "text/html;charset=utf-8")
    public CompletableFuture<RockerWritable> fortunes() {
        CompletableFuture<RockerWritable> result = new CompletableFuture<>();
        if (pool == null) {
            result.complete(new RockerWritable(views.fortunes.template(List.of())));
            return result;
        }
        pool.preparedQuery("SELECT id, message FROM fortune").execute().onComplete(ar -> {
            if (ar.failed()) {
                result.completeExceptionally(ar.cause());
                return;
            }
            List<Fortune> fortunes = new ArrayList<>(ar.result().size() + 1);
            for (Row row : ar.result()) {
                fortunes.add(new Fortune(row.getInteger("id"), row.getString("message")));
            }
            fortunes.add(new Fortune(0, "Additional fortune added at request time."));
            fortunes.sort(Comparator.comparing(Fortune::message));
            result.complete(new RockerWritable(views.fortunes.template(fortunes)));
        });
        return result;
    }
}
