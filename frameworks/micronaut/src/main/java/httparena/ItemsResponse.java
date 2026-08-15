package httparena;

import java.util.List;

/** {"items":[...],"count":N} */
public record ItemsResponse(List<PricedItem> items, int count) {
}
