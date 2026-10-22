package httparena;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CompletableFuture;

import com.fizzed.rocker.runtime.ArrayOfByteArraysOutput;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.Row;

/** GET /fortunes: rendered by the precompiled Rocker template views/fortunes.rocker.html, which escapes HTML by default. */
@Controller("/fortunes")
public class FortunesController {

    private final Pool pool;

    FortunesController(Database database) {
        this.pool = database.pool();
    }

    public record Fortune(int id, String message) {
    }

    @Get(produces = "text/html;charset=utf-8")
    public CompletableFuture<byte[]> fortunes() {
        CompletableFuture<byte[]> result = new CompletableFuture<>();
        if (pool == null) {
            result.complete(views.fortunes.template(List.of()).render(ArrayOfByteArraysOutput.FACTORY).toByteArray());
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
            result.complete(views.fortunes.template(fortunes).render(ArrayOfByteArraysOutput.FACTORY).toByteArray());
        });
        return result;
    }
}
