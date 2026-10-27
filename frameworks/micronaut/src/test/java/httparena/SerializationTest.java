package httparena;

import io.micronaut.context.ApplicationContext;
import io.micronaut.core.type.Argument;
import io.micronaut.json.JsonMapper;
import io.micronaut.serde.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SerializationTest {
    @Test
    void readsDatasetAndWritesCompleteResponsesWithoutDatabind() throws Exception {
        try (ApplicationContext context = ApplicationContext.run()) {
            ObjectMapper mapper = context.getBean(ObjectMapper.class);
            assertSame(mapper, context.getBean(JsonMapper.class));
            String itemJson = "{\"id\":1,\"name\":\"Café <&> 日本語\",\"category\":\"test\","
                    + "\"price\":7,\"quantity\":3,\"active\":false,\"tags\":[\"a\\tb\",\"\\\"quoted\\\"\"],"
                    + "\"rating\":{\"score\":4,\"count\":11}}";
            Item item = new Item(1, "Café <&> 日本語", "test", 7, 3, false,
                    List.of("a\tb", "\"quoted\""), new Rating(4, 11));
            assertEquals(List.of(item), mapper.readValue("[" + itemJson + "]", Argument.listOf(Item.class)));
            PricedItem priced = new PricedItem(item.id(), item.name(), item.category(), item.price(),
                    item.quantity(), item.active(), item.tags(), item.rating(), 42);
            assertEquals("{\"items\":[" + itemJson.substring(0, itemJson.length() - 1)
                    + ",\"total\":42}],\"count\":1}", mapper.writeValueAsString(new ItemsResponse(List.of(priced), 1)));
            assertEquals("{\"items\":[],\"count\":0}", mapper.writeValueAsString(new ItemsResponse(List.of(), 0)));
            assertThrows(ClassNotFoundException.class, () -> Class.forName("tools.jackson.databind.ObjectMapper"));
            assertThrows(ClassNotFoundException.class, () -> Class.forName("com.fasterxml.jackson.databind.ObjectMapper"));
        }
    }
}
