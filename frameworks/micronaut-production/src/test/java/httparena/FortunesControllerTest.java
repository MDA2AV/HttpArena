package httparena;

import com.fizzed.rocker.runtime.ArrayOfByteArraysOutput;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FortunesControllerTest {
    @Test
    void rendersTheSameEscapedUtf8DirectlyToBytes() {
        List<FortunesController.Fortune> rows = List.of(
                new FortunesController.Fortune(1, "<script>日本語 & 😀</script>"));
        String expected = views.fortunes.template(rows).render().toString();
        String actual = new String(views.fortunes.template(rows)
                .render(ArrayOfByteArraysOutput.FACTORY).toByteArray(), StandardCharsets.UTF_8);
        assertEquals(expected, actual);
        assertTrue(actual.contains("&lt;script&gt;"));
        assertTrue(actual.contains("日本語"));
        assertFalse(actual.contains("<script>"));
    }
}
