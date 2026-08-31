package httparena;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.jooby.Jooby;
import io.jooby.MediaType;
import io.jooby.ServerOptions;
import io.jooby.SslOptions;
import io.jooby.jackson.JacksonModule;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

public class App extends Jooby {

  private static final int MAX_BODY = 64 * 1024 * 1024;
  private static final ObjectMapper MAPPER = new ObjectMapper();

  /** Read once at startup, then only read from handlers, so threads share one copy. */
  private final List<Item> dataset = loadDataset();

  public App() {
    // Both thread counts are set explicitly, and that is load-bearing.
    //
    // JettyServer.setOptions does setWorkerThreads(getWorkerThreads(THREADS))
    // with a hardcoded THREADS = 200, so leaving it unset does NOT fall back to
    // Jooby's own WORKER_THREADS (cores * 8) -- it pins the pool at 200. And
    // Jetty sizes its selectors from ioThreads, which defaults to cores * 2.
    // On the 64-core/128-thread bench box that is 256 selectors against a
    // 200-thread pool, so Jetty's ThreadPoolBudget throws
    // "Insufficient configured threads: required=290 < max=200" and the JVM
    // exits before it ever listens. It only shows up above ~48 cores, which is
    // why a smaller machine starts fine.
    int cores = Runtime.getRuntime().availableProcessors();
    ServerOptions options = new ServerOptions()
        .setPort(8080)
        .setIoThreads(cores)
        .setWorkerThreads(Math.max(512, cores * 8))
        .setMaxRequestSize(MAX_BODY)
        .setCompressionLevel(1);   // json-comp: gzip at the level the profile asks for

    // json-tls on 8081. The harness mounts /certs only for the TLS profiles,
    // so a missing pair leaves the listener down rather than aborting startup.
    Path cert = Path.of("/certs/server.crt");
    Path key = Path.of("/certs/server.key");
    if (Files.exists(cert) && Files.exists(key)) {
      options.setSecurePort(8081);
      options.setSsl(SslOptions.x509(cert.toString(), key.toString()));
    }
    setServerOptions(options);

    install(new JacksonModule(MAPPER));


    get("/baseline11", ctx -> baseline(ctx));
    post("/baseline11", ctx -> baseline(ctx));

    get("/json/{count}", ctx -> {
      int count = ctx.path("count").intValue(0);
      long m = ctx.query("m").longValue(1L);
      int n = Math.min(Math.max(count, 0), dataset.size());
      List<OutItem> items = new ArrayList<>(n);
      for (int i = 0; i < n; i++) {
        Item d = dataset.get(i);
        items.add(new OutItem(d, d.price * d.quantity * m));
      }
      ctx.setResponseType(MediaType.json);
      return new OutList(items, n);
    });

    post("/echo", ctx -> {
      // Collected: the response needs a Content-Length, and a chunked request
      // carries none to forward until the body is in.
      byte[] body;
      try (InputStream in = ctx.body().stream()) {
        body = in.readAllBytes();
      }
      ctx.setResponseType(MediaType.valueOf("application/octet-stream"));
      return body;
    });
  }

  /**
   * Sum of every query parameter whose value parses as an integer, plus the body
   * when there is one. A non-numeric value is skipped rather than failing.
   */
  private Object baseline(io.jooby.Context ctx) {
    long total = 0;
    for (var entry : ctx.query().toMultimap().entrySet()) {
      for (String value : entry.getValue()) {
        try {
          total += Long.parseLong(value.trim());
        } catch (NumberFormatException ignored) {
          // not a number: skip it
        }
      }
    }
    String body = new String(ctx.body().bytes(), StandardCharsets.UTF_8);
    if (!body.isEmpty()) {
      try {
        total += Long.parseLong(body.trim());
      } catch (NumberFormatException ignored) {
        // no integer in the body: nothing to add
      }
    }
    ctx.setResponseType(MediaType.text);
    return Long.toString(total);
  }

  private static List<Item> loadDataset() {
    String path = System.getenv().getOrDefault("DATASET_PATH", "/data/dataset.json");
    try {
      return List.of(MAPPER.readValue(Files.readAllBytes(Path.of(path)), Item[].class));
    } catch (IOException e) {
      // No dataset is not fatal: /json then answers with an empty list.
      return List.of();
    }
  }

  public static void main(String[] args) {
    runApp(args, App::new);
  }
}
