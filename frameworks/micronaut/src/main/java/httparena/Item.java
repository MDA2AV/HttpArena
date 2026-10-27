package httparena;

import io.micronaut.serde.annotation.Serdeable;

import java.util.List;

/** One dataset record, as read from dataset.json. */
@Serdeable
public record Item(
        long id,
        String name,
        String category,
        long price,
        long quantity,
        boolean active,
        List<String> tags,
        Rating rating) {
}
