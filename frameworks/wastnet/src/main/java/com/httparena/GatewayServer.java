package com.httparena;

import io.github.wycst.wastnet.http.HTTPServer;
import io.github.wycst.wastnet.http.HttpOptions;
import io.github.wycst.wastnet.http.annotation.AnnotationRouterHandler;
import io.github.wycst.wastnet.http.handler.HttpResourceRoute;
import io.github.wycst.wastnet.socket.tcp.NioConfig;

/**
 * Gateway backend: the wastnet application server for the gateway-64 stack.
 * Listens ONLY on :8082 (h2c, prior-knowledge) because the edge proxy
 * (GatewayProxy) terminates TLS/h2 on :8443 and forwards dynamic requests to
 * 127.0.0.1:8082 over h2c. Nothing routes to :8080 in this topology — that
 * port belongs to Main (the standalone single-container entrypoint). Serves
 * the same controllers as Main. Used by compose.gateway.yml (the "server"
 * service).
 */
public final class GatewayServer {
    private static final String STATIC_DIR = "/data/static";

    public static void main(String[] args) throws Exception {
        AnnotationRouterHandler router = new AnnotationRouterHandler()
                .messageConverter(new JsonMessageConverter())
                .scanPackages("com.httparena");
        router.resource(new HttpResourceRoute("/static", STATIC_DIR));

        // h2c (cleartext HTTP/2, prior knowledge) listener for the edge proxy's
        // upstream. The proxy speaks h2c to this port, so a single multiplexed
        // connection carries all 32 streams of one client H2 connection. Must
        // match the proxy's HttpProxyConfig.target("http://127.0.0.1:8082").h2c(true).
        NioConfig h2cConfig = new NioConfig().testMode();
        h2cConfig.option(HttpOptions.GZIP, true);
        h2cConfig.setWriteBufferSize(16384);
        HTTPServer.of(8082, h2cConfig)
                .applicationProtocols("h2c")
                .requestHandler(router)
                .start();
        System.out.println("[Gateway] backend on :8082 (h2c, for proxy upstream)");
        Thread.currentThread().join();
    }
}
