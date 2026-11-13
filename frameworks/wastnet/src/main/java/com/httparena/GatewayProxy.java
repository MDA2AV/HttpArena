package com.httparena;

import io.github.wycst.wastnet.http.HTTPServer;
import io.github.wycst.wastnet.http.HttpOptions;
import io.github.wycst.wastnet.http.handler.HttpResourceRoute;
import io.github.wycst.wastnet.http.handler.HttpRouterHandler;
import io.github.wycst.wastnet.http.proxy.HttpProxyConfig;
import io.github.wycst.wastnet.socket.tcp.NioConfig;

/**
 * Gateway edge: terminates TLS + HTTP/2 on :8443, serves /static/* from local
 * disk (per the gateway spec), and reverse-proxies the remaining dynamic
 * requests to the wastnet backend on 127.0.0.1:8082 over h2c.
 * Used by compose.gateway.yml (the "proxy" service).
 */
public final class GatewayProxy {
    private static final String CERT_FILE = "/certs/server.crt";
    private static final String KEY_FILE = "/certs/server.key";
    private static final String STATIC_DIR = "/data/static";

    public static void main(String[] args) throws Exception {
        // h2c upstream to the backend: one multiplexed conn per client (not 32),
        // avoiding the old H1.1 per-stream conn explosion that exhausted sockets.
        HttpRouterHandler router = new HttpRouterHandler("/");
        // Serve /static/* from local disk (gateway spec: not forwarded to backend).
        router.resource(new HttpResourceRoute("/static", STATIC_DIR).detectPreCompressed(true));
        router.proxy("/", HttpProxyConfig.target("http://127.0.0.1:8082").h2c(true));

        HTTPServer.of(8443, new NioConfig().testMode())
                .pemSSL(CERT_FILE, KEY_FILE)
                .h2()
                .requestHandler(router)
                .start();

        System.out.println("[Gateway] edge proxy h2/TLS :8443 -> 127.0.0.1:8082 (h2c)");
        Thread.currentThread().join();
    }
}
