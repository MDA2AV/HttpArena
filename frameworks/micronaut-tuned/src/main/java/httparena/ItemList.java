package httparena;

import io.micronaut.serde.annotation.Serdeable;

import java.util.List;

/** {"items":[...],"count":N} for the database profile. */
@Serdeable
public record ItemList(List<Item> items, int count) {
}
