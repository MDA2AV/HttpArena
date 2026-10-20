package httparena;

import java.util.List;

public final class JsonDtos {
    private JsonDtos() {}

    record Rating(long score, long count) {}

    record Item(long id, String name, String category, long price, long quantity, boolean active, List<String> tags, Rating rating) {}

    record TotalItem(long id, String name, String category, long price, long quantity, boolean active, List<String> tags, Rating rating, long total) {
        static TotalItem from(Item item, long m) {
          return new TotalItem(item.id(), item.name(), item.category(), item.price(), item.quantity(), item.active(), item.tags(), item.rating(), item.price() * item.quantity() * m);
        }
    }

    record ItemResponse(List<TotalItem> items, int count) {}
}
