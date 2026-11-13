package httparena;

import io.micronaut.context.ApplicationContext;
import io.micronaut.core.type.Argument;
import io.micronaut.serde.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SerializationTest {
    @Test
    void readsDatasetAndDatabaseTagsAndWritesResponsesWithoutDatabind() throws Exception {
        try (ApplicationContext context = ApplicationContext.run()) {
            ObjectMapper mapper = context.getBean(ObjectMapper.class);
            List<String> tags = mapper.readValue("[\"日本語\",\"a\\tb\",\"\\\"quoted\\\"\"]", Argument.listOf(String.class));
            assertEquals(List.of("日本語", "a\tb", "\"quoted\""), tags);
            Item item = new Item(1, "Café <&>", "test", 7, 3, true, tags, new Rating(4, 11));
            assertEquals(List.of(item), mapper.readValue(mapper.writeValueAsBytes(List.of(item)), Argument.listOf(Item.class)));
            ItemList response = new ItemList(List.of(item), 1);
            assertEquals(response, mapper.readValue(mapper.writeValueAsBytes(response), ItemList.class));
            assertEquals(new ItemList(List.of(), 0), mapper.readValue("{\"items\":[],\"count\":0}", ItemList.class));
            assertThrows(ClassNotFoundException.class, () -> Class.forName("tools.jackson.databind.ObjectMapper"));
            assertThrows(ClassNotFoundException.class, () -> Class.forName("com.fasterxml.jackson.databind.ObjectMapper"));
        }
    }
}
