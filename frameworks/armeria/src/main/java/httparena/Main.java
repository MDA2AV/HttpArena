package httparena;

import java.io.File;
import java.nio.file.Path;
import java.time.Duration;

import com.linecorp.armeria.common.HttpResponse;
import com.linecorp.armeria.common.HttpStatus;
import com.linecorp.armeria.common.MediaType;
import com.linecorp.armeria.server.Server;
import com.linecorp.armeria.server.ServerBuilder;
import com.linecorp.armeria.server.ServiceRequestContext;
import com.linecorp.armeria.server.encoding.EncodingService;
import com.linecorp.armeria.server.file.FileService;
import com.linecorp.armeria.server.grpc.GrpcService;
import com.linecorp.armeria.server.websocket.WebSocketService;

public final class Main {

    private static final File CERT = new File("/certs/server.crt");
    private static final File KEY = new File("/certs/server.key");

    public static void main(String[] args) throws Exception {
        final String datasetPath = System.getenv().getOrDefault("DATASET_PATH", "/data/dataset.json");
        final JsonService json = new JsonService(Path.of(datasetPath));

        // 8080: HTTP/1.1 + h2c (gRPC), 8082: h2c prior-knowledge.
        final ServerBuilder sb = Server.builder()
                                       .http(8080)
                                       .http(8082);
        // 8081: json-tls, 8gbit, static-tls. 8443: h2 and gRPC over TLS.
        if (CERT.isFile() && KEY.isFile()) {
            sb.https(8081)
              .https(8443)
              .tls(CERT, KEY);
        }

        sb.service("/pipeline", (ctx, req) -> HttpResponse.of("ok"))
          .service("/baseline11", new BaselineService())
          .service("/baseline2", new BaselineService())
          .service("/delay/{ms}", (ctx, req) -> delay(ctx))
          .service("/json/{count}", json.decorate(EncodingService.builder()
                                                     // ofJson() sends `application/json` without a charset.
                                                     .encodableContentTypes(MediaType.JSON)
                                                     .newDecorator()))
          .service("/echo", (ctx, req) -> HttpResponse.of(
                  req.aggregate().thenApply(agg -> HttpResponse.of(
                          HttpStatus.OK, MediaType.OCTET_STREAM, agg.content()))))
          .serviceUnder("/static/", FileService.builder(Path.of("/data/static"))
                                               .serveCompressedFiles(true)
                                               .build())
          .service("/ws", WebSocketService.builder(new EchoWebSocketHandler())
                                         // Load generators send no Origin header.
                                         .allowedOrigins("*")
                                         .build())
          .service(GrpcService.builder()
                              .addService(new BenchmarkGrpcService())
                              .build());

        final Server server = sb.build();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> server.stop().join()));
        server.start().join();
    }

    private static HttpResponse delay(ServiceRequestContext ctx) {
        final long ms;
        try {
            ms = Long.parseLong(ctx.pathParam("ms"));
        } catch (NumberFormatException e) {
            return HttpResponse.of(HttpStatus.NOT_FOUND);
        }
        final HttpResponse res = HttpResponse.of(Long.toString(ms));
        return ms <= 0 ? res : HttpResponse.delayed(res, Duration.ofMillis(ms), ctx.eventLoop());
    }

    private Main() {}
}
