package httparena;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

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

    private static void assertEscaped(String input, String expected) {
        StringBuilder output = new StringBuilder("prefix:");
        FortunesController.escape(output, input);
        assertEquals("prefix:" + expected, output.toString());
    }
}
