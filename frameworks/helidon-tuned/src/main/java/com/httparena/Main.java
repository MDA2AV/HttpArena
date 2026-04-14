package com.httparena;

import io.helidon.config.Config;
import io.helidon.http.Header;
import io.helidon.http.HeaderNames;
import io.helidon.http.HeaderValues;
import io.helidon.logging.common.LogConfig;
import io.helidon.webserver.WebServer;
import io.helidon.webserver.grpc.GrpcRouting;
import io.helidon.webserver.websocket.WsRouting;

public final class Main {
    static final Header SERVER_HEADER = HeaderValues.createCached(HeaderNames.SERVER, "helidon");

    static {
        LogConfig.initClass();
    }

    private Main() {
    }

    public static void main(String[] args) throws Exception {
        LogConfig.configureRuntime();

        Config config = Config.create();
        Config serverConfig = config.get("server");
        String dataLocation = config.get("data.dir").asString().orElse("/data");

        BenchmarkGrpcService grpcService = new BenchmarkGrpcService();
        var builder = WebServer.builder()
                .config(serverConfig);

        JsonHandler jsonHandler = new JsonHandler(dataLocation);
        BaselineHandler baselineHandler = new BaselineHandler();
        StaticHandler staticHandler = new StaticHandler(dataLocation);

        // default listener routing
        builder.routing(httpRouting -> httpRouting
                        .get("/pipeline", new PipelineHandler())
                        .get("/baseline11", baselineHandler)
                        .get("/json/{count}", jsonHandler)
                        .get("/json", jsonHandler)
                        .get("/static/{filename}", staticHandler)
                        .post("/baseline11", new BaselinePostHandler())
                        .post("/upload", new UploadHandler())
                        .get("/async-db", new DbHandler()))
                .addRouting(GrpcRouting.builder().service(grpcService))
                .addRouting(WsRouting.builder().endpoint("/ws", new EchoWsListener()));

        // h2-tls routing - baseline2, static content, GRPC
        var h2TlsListener = builder.sockets().get("h2-tls");
        if (h2TlsListener != null) {
            builder.putSocket("h2-tls", socket -> socket
                    .from(h2TlsListener)
                    .routing(routing -> routing
                            .get("/baseline2", baselineHandler)
                            .get("/static/{filename}", staticHandler))
                    .addRouting(GrpcRouting.builder().service(grpcService)));
        }

        // h1-tls routing - json-tls only
        var h1TlsListener = builder.sockets().get("h1-tls");
        if (h1TlsListener != null) {
            builder.putSocket("h1-tls", socket -> socket
                    .from(h1TlsListener)
                    .routing(routing -> routing
                            .get("/json/{count}", jsonHandler)
                            .get("/json", jsonHandler)));
        }

        WebServer server = builder.build().start();

        int defaultPort = server.port();
        int h2TlsPort = server.port("h2-tls");
        int h1TlsPort = server.port("h1-tls");

        if (defaultPort == -1 || h2TlsPort == -1 || h1TlsPort == -1) {
            server.stop();
            System.err.println("Helidon HttpArena server failed to start");
            System.exit(-1);
        }

        System.out.println("Helidon HttpArena server started on ports: "
                                   + "\nplain (" + server.port() + ")"
                                   + "\nhttps (" + server.port("h2-tls") + ")"
                                   + "\nh1tls (" + server.port("h1-tls") + ")");
    }
}
