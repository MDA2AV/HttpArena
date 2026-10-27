package httparena;

import java.util.concurrent.TimeUnit;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;


import io.micronaut.core.annotation.Nullable;
import io.micronaut.http.HttpRequest;
import io.micronaut.http.MediaType;
import io.micronaut.http.annotation.Body;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.PathVariable;
import io.micronaut.http.annotation.Post;
import io.micronaut.http.annotation.QueryValue;
import io.netty.util.concurrent.EventExecutor;
import io.netty.util.internal.ThreadExecutorMap;

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

    // A delayed CompletableFuture rather than a sleep: nothing holds a request thread while the
    // wait runs, so the waits in flight are bounded by memory rather than by the pool. The JDK's
    // delayedExecutor keeps this to the standard library - the entry has no reactive dependency.
    @Get(value = "/delay/{ms}", produces = MediaType.TEXT_PLAIN)
    public CompletableFuture<String> delay(int ms) {
        String body = Integer.toString(ms);

        if (ms <= 0) {
            return CompletableFuture.completedFuture(body);
        }

        // Complete on the event loop that runs this request: no hop to another thread and back
        EventExecutor loop = ThreadExecutorMap.currentExecutor();
        if (loop == null) {
            return CompletableFuture.supplyAsync(
                    () -> body, CompletableFuture.delayedExecutor(ms, TimeUnit.MILLISECONDS));
        }
        CompletableFuture<String> future = new CompletableFuture<>();
        loop.schedule(() -> future.complete(body), ms, TimeUnit.MILLISECONDS);
        return future;
    }

    @Get(value = "/baseline2", produces = MediaType.TEXT_PLAIN)
    public String baseline2(@QueryValue @Nullable String a, @QueryValue @Nullable String b) {
        return Long.toString(parseLong(a, 0) + parseLong(b, 0));
    }

    @Get(value = "/baseline11", produces = MediaType.TEXT_PLAIN)
    public String baselineGet(@QueryValue @Nullable String a, @QueryValue @Nullable String b) {
        return Long.toString(parseLong(a, 0) + parseLong(b, 0));
    }

    @Post(value = "/baseline11", consumes = MediaType.ALL, produces = MediaType.TEXT_PLAIN)
    public String baselinePost(@QueryValue @Nullable String a, @QueryValue @Nullable String b, @Body @Nullable byte[] body) {
        long sum = parseLong(a, 0) + parseLong(b, 0);
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

    /** The framework aggregates the body, which also covers a chunked request, and the echo returns it. */
    @Post(value = "/echo", consumes = MediaType.ALL, produces = MediaType.APPLICATION_OCTET_STREAM)
    public byte[] echoBody(@Body @Nullable byte[] body) {
        return body == null ? new byte[0] : body;
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
