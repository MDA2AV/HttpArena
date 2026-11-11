package httparena;

import com.linecorp.armeria.common.HttpMethod;
import com.linecorp.armeria.common.HttpRequest;
import com.linecorp.armeria.common.HttpResponse;
import com.linecorp.armeria.server.HttpService;
import com.linecorp.armeria.server.ServiceRequestContext;

/** {@code /baseline11} and {@code /baseline2}: sum of {@code a}, {@code b} and the POST body. */
final class BaselineService implements HttpService {

    @Override
    public HttpResponse serve(ServiceRequestContext ctx, HttpRequest req) {
        final long sum = parse(ctx.queryParam("a")) + parse(ctx.queryParam("b"));
        if (req.method() != HttpMethod.POST) {
            return HttpResponse.of(Long.toString(sum));
        }
        return HttpResponse.of(req.aggregate().thenApply(
                agg -> HttpResponse.of(Long.toString(sum + parse(agg.contentUtf8())))));
    }

    private static long parse(String value) {
        if (value == null) {
            return 0;
        }
        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return 0;
        }
    }
}
