package httparena;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Random;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufUtil;
import io.netty.buffer.Unpooled;
import io.vertx.core.Promise;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.PreparedQuery;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowIterator;
import io.vertx.sqlclient.RowSet;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

class FortunesControllerTest {
    @Test
    void escapesHtmlWithoutChangingUnicodeOrUnescapedSpans() {
        assertEscaped("", "");
        assertEscaped("plain 日本語 😀", "plain 日本語 😀");
        assertEscaped("<&>\"'", "&lt;&amp;&gt;&quot;&#39;");
        assertEscaped("before <script>日本語 & 😀</script> after",
                "before &lt;script&gt;日本語 &amp; 😀&lt;/script&gt; after");
        assertEscaped("&&tail&", "&amp;&amp;tail&amp;");
    }

    @Test
    void matchesJdkEncodingForEveryUtf16CodeUnitAndMalformedSurrogateSequence() {
        StringBuilder all = new StringBuilder();
        for (int c = 0; c <= Character.MAX_VALUE; c++) {
            all.append((char) c).append('x');
        }
        assertMatchesLegacy(all.toString());
        assertMatchesLegacy("\ud800\ud800\udc00\ud800日本語\udc00<&>\"'\ud800");
        Random random = new Random(42);
        for (int n = 0; n < 100; n++) {
            StringBuilder text = new StringBuilder();
            for (int i = 0; i < 1000; i++) {
                text.append((char) random.nextInt(Character.MAX_VALUE + 1));
            }
            assertMatchesLegacy(text.toString());
        }
    }

    @Test
    void rendersAllRowsAndCanGrowBeyondInitialCapacity() {
        List<FortunesController.Fortune> rows = new ArrayList<>();
        for (int id = 1; id <= 200; id++) {
            rows.add(new FortunesController.Fortune(id, "日本語 😀 <&>\"' ".repeat(30) + id));
        }
        rows.add(new FortunesController.Fortune(0, "Additional fortune added at request time."));
        rows.sort(Comparator.comparing(FortunesController.Fortune::message));
        byte[] output = FortunesController.render(rows);
        String html = new String(output, StandardCharsets.UTF_8);
        assertTrue(output.length > 32 * 1024);
        assertTrue(html.startsWith("<!DOCTYPE html>"));
        assertTrue(html.endsWith("</table></body></html>"));
        assertEquals(201, html.split("<tr><td>", -1).length - 1);
        assertTrue(html.contains("<td>0</td><td>Additional fortune added at request time.</td>"));
        for (FortunesController.Fortune row : rows) {
            assertTrue(html.contains("<td>" + row.id() + "</td><td>" + legacyEscape(row.message()) + "</td>"));
        }
    }

    @Test
    void queriesFreshRowsSortsAndAddsRuntimeFortune() {
        try (QueryFixture fixture = new QueryFixture()) {
            for (int request = 0; request < 2; request++) {
                CompletableFuture<byte[]> response = fixture.controller.fortunes();
                List<Row> rows = new ArrayList<>();
                for (int id = 1; id <= 200; id++) {
                    int rowId = id;
                    String message = (201 - id) + " request " + request + " <&>\"' 😀";
                    rows.add(proxy(Row.class, (p, method, args) -> switch (method.getName()) {
                        case "getInteger" -> rowId;
                        case "getString" -> message;
                        default -> throw new AssertionError(method);
                    }));
                }
                fixture.pending.complete(rowSet(rows));
                String html = new String(response.join(), StandardCharsets.UTF_8);
                assertEquals(201, html.split("<tr><td>", -1).length - 1);
                assertTrue(html.contains("<td>0</td><td>Additional fortune added at request time.</td>"));
                assertTrue(html.indexOf("<td>200</td>") < html.indexOf("<td>199</td>"));
                assertTrue(html.contains("request " + request + " &lt;&amp;&gt;&quot;&#39; 😀"));
            }
            assertEquals(2, fixture.queries);
        }
    }

    @Test
    void propagatesQueryFailuresAndAcceptsCancellationBeforeRowsArrive() {
        try (QueryFixture fixture = new QueryFixture()) {
            CompletableFuture<byte[]> failed = fixture.controller.fortunes();
            RuntimeException cause = new RuntimeException("query failed");
            fixture.pending.fail(cause);
            assertSame(cause, assertThrows(CompletionException.class, failed::join).getCause());

            CompletableFuture<byte[]> cancelled = fixture.controller.fortunes();
            assertTrue(cancelled.cancel(false));
            fixture.pending.complete(rowSet(List.of()));
            assertTrue(cancelled.isCancelled());
        }
    }

    private static <T> T proxy(Class<T> type, InvocationHandler handler) {
        return type.cast(Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{type}, handler));
    }

    @SuppressWarnings("unchecked")
    private static RowSet<Row> rowSet(List<Row> rows) {
        return proxy(RowSet.class, (p, method, args) -> switch (method.getName()) {
            case "size" -> rows.size();
            case "iterator" -> {
                var iterator = rows.iterator();
                yield proxy(RowIterator.class, (i, m, a) -> switch (m.getName()) {
                    case "hasNext" -> iterator.hasNext();
                    case "next" -> iterator.next();
                    default -> throw new AssertionError(m);
                });
            }
            default -> throw new AssertionError(method);
        });
    }

    private static final class QueryFixture implements AutoCloseable {
        private Promise<RowSet<Row>> pending;
        private int queries;
        private final Pool pool = proxy(Pool.class, (p, method, args) -> {
            assertEquals("preparedQuery", method.getName());
            assertEquals("SELECT id, message FROM fortune", args[0]);
            queries++;
            return proxy(PreparedQuery.class, (q, queryMethod, queryArgs) -> {
                assertEquals("execute", queryMethod.getName());
                pending = Promise.promise();
                return pending.future();
            });
        });
        private final Database database = new Database() {
            @Override
            Pool pool() {
                return pool;
            }
        };
        private final FortunesController controller = new FortunesController(database);

        @Override
        public void close() {
            database.close();
        }
    }

    private static void assertMatchesLegacy(String input) {
        ByteBuf output = Unpooled.buffer();
        try {
            FortunesController.escape(output, input);
            assertArrayEquals(legacyEscape(input).getBytes(StandardCharsets.UTF_8), ByteBufUtil.getBytes(output));
        } finally {
            output.release();
        }
    }

    private static String legacyEscape(String input) {
        return input.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                .replace("\"", "&quot;").replace("'", "&#39;");
    }

    private static void assertEscaped(String input, String expected) {
        ByteBuf output = Unpooled.buffer();
        try {
            ByteBufUtil.writeAscii(output, "prefix:");
            FortunesController.escape(output, input);
            assertEquals("prefix:" + expected, output.toString(StandardCharsets.UTF_8));
        } finally {
            output.release();
        }
    }
}
