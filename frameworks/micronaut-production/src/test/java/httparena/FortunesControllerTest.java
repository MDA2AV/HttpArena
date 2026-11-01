package httparena;

import io.micronaut.views.rocker.RockerWritable;
import io.micronaut.views.rocker.RockerWriterOutput;
import io.micronaut.context.ApplicationContext;
import io.micronaut.runtime.server.EmbeddedServer;
import org.junit.jupiter.api.Test;

import java.io.StringWriter;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FortunesControllerTest {
    @Test
    void rendersTemplateTextWithoutDecodingByteFragments() {
        StringWriter output = new StringWriter();
        views.fortunes.template(List.of(new FortunesController.Fortune(1, "<日本語 & 😀>")))
                .render((type, charset) -> new RockerWriterOutput(output, type, charset) {
                    @Override
                    public RockerWriterOutput w(byte[] bytes) {
                        throw new AssertionError("The Views writer should receive character fragments");
                    }
                });
        assertTrue(output.toString().contains("&lt;日本語 &amp; 😀&gt;"));
    }

    @Test
    void rendersThroughMicronautViewsWithHtmlEscaping() throws Exception {
        List<FortunesController.Fortune> rows = List.of(
                new FortunesController.Fortune(1, "<script>日本語 & 😀</script>"));
        String expected = views.fortunes.template(rows).render().toString();
        StringWriter output = new StringWriter();
        new RockerWritable(views.fortunes.template(rows)).writeTo(output);
        String actual = output.toString();
        assertEquals(expected, actual);
        assertTrue(actual.contains("&lt;script&gt;"));
        assertTrue(actual.contains("日本語"));
        assertFalse(actual.contains("<script>"));
    }

    @Test
    void servesFortunesThroughTheFrameworkResponseWriter() throws Exception {
        Map<String, Object> properties = new HashMap<>();
        for (String listener : new String[]{"http", "https", "h2tls", "h2c", "h3"}) {
            properties.put("micronaut.server.netty.listeners." + listener + ".port", -1);
            properties.put("micronaut.server.netty.listeners." + listener + ".ssl", false);
            properties.put("micronaut.server.netty.listeners." + listener + ".family", "TCP");
        }
        properties.put("micronaut.netty.event-loops.default.num-threads", 2);
        try (ApplicationContext context = ApplicationContext.run(properties);
             HttpClient client = HttpClient.newHttpClient()) {
            EmbeddedServer server = context.getBean(EmbeddedServer.class).start();
            HttpResponse<String> response = client.send(HttpRequest.newBuilder(
                    URI.create("http://localhost:" + server.getPort() + "/fortunes"))
                    .timeout(Duration.ofSeconds(10)).GET().build(), HttpResponse.BodyHandlers.ofString());
            assertEquals(200, response.statusCode());
            assertTrue(response.headers().firstValue("content-type").orElseThrow().startsWith("text/html"));
            assertTrue(response.body().contains("<!DOCTYPE html>"));
            assertTrue(response.body().contains("<table>"));
        }
    }
}
