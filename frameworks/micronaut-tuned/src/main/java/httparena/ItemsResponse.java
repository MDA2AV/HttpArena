package httparena;

import io.micronaut.serde.annotation.Serdeable;

import java.util.List;

/** {"items":[...],"count":N} */
@Serdeable
public record ItemsResponse(List<PricedItem> items, int count) {
}
