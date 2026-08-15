package httparena;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicLong;

import org.reactivestreams.Publisher;
import org.reactivestreams.Subscriber;
import org.reactivestreams.Subscription;

import io.micronaut.core.annotation.Nullable;
import io.micronaut.http.HttpRequest;
import io.micronaut.http.MediaType;
import io.micronaut.http.annotation.Body;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.PathVariable;
import io.micronaut.http.annotation.Post;
import io.micronaut.http.annotation.QueryValue;

@Controller
public class BenchmarkController {

    private final Dataset dataset;

    BenchmarkController(Dataset dataset) {
        this.dataset = dataset;
    }

    @Get(value = "/pipeline", produces = MediaType.TEXT_PLAIN)
    public String pipeline() {
        return "ok";
    }

    @Get(value = "/baseline11", produces = MediaType.TEXT_PLAIN)
    public String baselineGet(HttpRequest<?> request) {
        return Long.toString(querySum(request));
    }

    @Post(value = "/baseline11", consumes = MediaType.ALL, produces = MediaType.TEXT_PLAIN)
    public String baselinePost(HttpRequest<?> request, @Body @Nullable byte[] body) {
        long sum = querySum(request);
        if (body != null && body.length > 0) {
            sum += parseLong(new String(body, StandardCharsets.UTF_8), 0);
        }
        return Long.toString(sum);
    }

    @Get(value = "/json/{count}", produces = MediaType.APPLICATION_JSON)
    public ItemsResponse json(@PathVariable String count,
                              @QueryValue(value = "m", defaultValue = "1") String m) {
        List<Item> source = dataset.items();
        int n = (int) Math.max(0, Math.min(parseLong(count, 0), source.size()));
        long multiplier = parseLong(m, 1);

        List<PricedItem> items = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            Item item = source.get(i);
            items.add(new PricedItem(
                    item.id(), item.name(), item.category(),
                    item.price(), item.quantity(), item.active(),
                    item.tags(), item.rating(),
                    item.price() * item.quantity() * multiplier));
        }
        return new ItemsResponse(items, n);
    }

    /**
     * The body is bound as a stream of chunks, so a 20 MB upload is counted as it
     * arrives instead of being held in memory.
     */
    @Post(value = "/upload", consumes = MediaType.ALL, produces = MediaType.TEXT_PLAIN)
    public CompletableFuture<String> upload(@Body @Nullable Publisher<byte[]> body) {
        CompletableFuture<String> received = new CompletableFuture<>();
        if (body == null) {
            received.complete("0");
            return received;
        }
        body.subscribe(new Subscriber<byte[]>() {

            private final AtomicLong size = new AtomicLong();

            @Override
            public void onSubscribe(Subscription subscription) {
                subscription.request(Long.MAX_VALUE);
            }

            @Override
            public void onNext(byte[] chunk) {
                size.addAndGet(chunk.length);
            }

            @Override
            public void onError(Throwable error) {
                received.completeExceptionally(error);
            }

            @Override
            public void onComplete() {
                received.complete(Long.toString(size.get()));
            }
        });
        return received;
    }

    private static long querySum(HttpRequest<?> request) {
        long sum = 0;
        for (Map.Entry<String, List<String>> parameter : request.getParameters()) {
            for (String value : parameter.getValue()) {
                sum += parseLong(value, 0);
            }
        }
        return sum;
    }

    private static long parseLong(String value, long fallback) {
        if (value == null) {
            return fallback;
        }
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException notANumber) {
            return fallback;
        }
    }
}
