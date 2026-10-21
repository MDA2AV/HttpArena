package httparena;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.views.View;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.Row;

/** GET /fortunes: rendered by the Thymeleaf template views/fortunes.html, which escapes th:text. */
@Controller("/fortunes")
public class FortunesController {

    private final Pool pool;

    FortunesController(Database database) {
        this.pool = database.pool();
    }

    public record Fortune(int id, String message) {
    }

    @View("fortunes")
    @Get(produces = "text/html;charset=utf-8")
    public CompletableFuture<Map<String, Object>> fortunes() {
        CompletableFuture<Map<String, Object>> result = new CompletableFuture<>();
        if (pool == null) {
            result.complete(Map.of("fortunes", List.of()));
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
            result.complete(Map.of("fortunes", fortunes));
        });
        return result;
    }
}
