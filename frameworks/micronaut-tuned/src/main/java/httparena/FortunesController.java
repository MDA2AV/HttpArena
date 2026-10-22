package httparena;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CompletableFuture;

import io.micronaut.http.MediaType;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.Row;

/** GET /fortunes: the page is emitted with a StringBuilder, escaping every message. */
@Controller("/fortunes")
public class FortunesController {

    private static final String PAGE_START = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body>"
            + "<table><tr><th>id</th><th>message</th></tr>";
    private static final String PAGE_END = "</table></body></html>";

    private final Pool pool;

    FortunesController(Database database) {
        this.pool = database.pool();
    }

    @Get(produces = "text/html;charset=utf-8")
    public CompletableFuture<byte[]> fortunes() {
        CompletableFuture<byte[]> result = new CompletableFuture<>();
        if (pool == null) {
            result.complete(new byte[0]);
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
            StringBuilder html = new StringBuilder(32 * 1024).append(PAGE_START);
            for (Fortune f : fortunes) {
                html.append("<tr><td>").append(f.id()).append("</td><td>");
                escape(html, f.message());
                html.append("</td></tr>");
            }
            result.complete(html.append(PAGE_END).toString().getBytes(StandardCharsets.UTF_8));
        });
        return result;
    }

    static void escape(StringBuilder out, String text) {
        int start = 0;
        for (int i = 0; i < text.length(); i++) {
            String replacement = switch (text.charAt(i)) {
                case '<' -> "&lt;";
                case '>' -> "&gt;";
                case '&' -> "&amp;";
                case '"' -> "&quot;";
                case '\'' -> "&#39;";
                default -> null;
            };
            if (replacement != null) {
                out.append(text, start, i).append(replacement);
                start = i + 1;
            }
        }
        out.append(text, start, text.length());
    }

    private record Fortune(int id, String message) {
    }
}
