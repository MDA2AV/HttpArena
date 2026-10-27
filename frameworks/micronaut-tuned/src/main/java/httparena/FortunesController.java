package httparena;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CompletableFuture;

import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufUtil;
import io.netty.buffer.Unpooled;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.Row;

/** GET /fortunes: the page is emitted directly as UTF-8, escaping every message. */
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
            try {
                List<Fortune> fortunes = new ArrayList<>(ar.result().size() + 1);
                for (Row row : ar.result()) {
                    fortunes.add(new Fortune(row.getInteger("id"), row.getString("message")));
                }
                fortunes.add(new Fortune(0, "Additional fortune added at request time."));
                fortunes.sort(Comparator.comparing(Fortune::message));
                result.complete(render(fortunes));
            } catch (Throwable e) {
                result.completeExceptionally(e);
            }
        });
        return result;
    }

    static byte[] render(List<Fortune> fortunes) {
        ByteBuf html = Unpooled.buffer(32 * 1024);
        try {
            ByteBufUtil.writeAscii(html, PAGE_START);
            for (Fortune f : fortunes) {
                ByteBufUtil.writeAscii(html, "<tr><td>");
                ByteBufUtil.writeAscii(html, Integer.toString(f.id()));
                ByteBufUtil.writeAscii(html, "</td><td>");
                escape(html, f.message());
                ByteBufUtil.writeAscii(html, "</td></tr>");
            }
            ByteBufUtil.writeAscii(html, PAGE_END);
            return ByteBufUtil.getBytes(html);
        } finally {
            html.release();
        }
    }

    static void escape(ByteBuf out, String text) {
        int start = 0;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            String replacement = switch (c) {
                case '<' -> "&lt;";
                case '>' -> "&gt;";
                case '&' -> "&amp;";
                case '"' -> "&quot;";
                case '\'' -> "&#39;";
                default -> {
                    if (Character.isHighSurrogate(c)) {
                        if (i + 1 < text.length() && Character.isLowSurrogate(text.charAt(i + 1))) {
                            i++;
                            yield null;
                        }
                        yield "?";
                    }
                    // Match String.getBytes(UTF_8) for malformed UTF-16 before Netty encodes the span.
                    yield Character.isLowSurrogate(c) ? "?" : null;
                }
            };
            if (replacement != null) {
                ByteBufUtil.writeUtf8(out, text, start, i);
                ByteBufUtil.writeAscii(out, replacement);
                start = i + 1;
            }
        }
        ByteBufUtil.writeUtf8(out, text, start, text.length());
    }

    record Fortune(int id, String message) {
    }
}
