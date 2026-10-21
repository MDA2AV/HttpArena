package httparena;

import io.micronaut.serde.annotation.Serdeable;

import java.util.List;

/** A dataset record plus the computed total, in the field order the profile asks for. */
@Serdeable
public record PricedItem(
        long id,
        String name,
        String category,
        long price,
        long quantity,
        boolean active,
        List<String> tags,
        Rating rating,
        long total) {
}
