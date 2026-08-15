package httparena;

import java.util.List;

/** A dataset record plus the computed total, in the field order the profile asks for. */
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
