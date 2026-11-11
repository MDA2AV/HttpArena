package httparena;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;

import com.linecorp.armeria.common.HttpRequest;
import com.linecorp.armeria.common.HttpResponse;
import com.linecorp.armeria.common.HttpStatus;
import com.linecorp.armeria.server.HttpService;
import com.linecorp.armeria.server.ServiceRequestContext;

/** {@code /json/{count}?m=N}: the first {@code count} items with {@code total = price * quantity * m}. */
final class JsonService implements HttpService {

    record Rating(long score, long count) {}

    record Item(long id, String name, String category, long price, long quantity,
                boolean active, List<String> tags, Rating rating) {}

    record TotalItem(long id, String name, String category, long price, long quantity,
                     boolean active, List<String> tags, Rating rating, long total) {}

    record Response(List<TotalItem> items, int count) {}

    private final List<Item> dataset;

    JsonService(Path path) throws IOException {
        final ObjectMapper mapper =
                new ObjectMapper().disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
        dataset = List.of(mapper.readValue(path.toFile(), Item[].class));
    }

    @Override
    public HttpResponse serve(ServiceRequestContext ctx, HttpRequest req) {
        final int count;
        final long m;
        try {
            count = Math.min(Math.max(Integer.parseInt(ctx.pathParam("count")), 0), dataset.size());
            final String mParam = ctx.queryParam("m");
            m = mParam == null ? 1 : Long.parseLong(mParam);
        } catch (NumberFormatException e) {
            return HttpResponse.of(HttpStatus.BAD_REQUEST);
        }

        final List<TotalItem> items = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            final Item it = dataset.get(i);
            items.add(new TotalItem(it.id(), it.name(), it.category(), it.price(), it.quantity(),
                                    it.active(), it.tags(), it.rating(), it.price() * it.quantity() * m));
        }
        return HttpResponse.ofJson(new Response(items, count));
    }
}
