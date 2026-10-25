package com.httparena;

import io.github.wycst.wastnet.http.HTTPServer;
import io.github.wycst.wastnet.http.HttpOptions;
import io.github.wycst.wastnet.http.annotation.AnnotationRouterHandler;
import io.github.wycst.wastnet.http.handler.HttpResourceRoute;
import io.github.wycst.wastnet.socket.tcp.NioConfig;

/**
 * HttpArena entry point.
 * <p>
 * One {@link AnnotationRouterHandler} is shared by four listeners so every protocol
 * serves the same controllers:
 * <ul>
 *   <li>8080 - HTTP/1.1 plaintext (+ WebSocket upgrade)</li>
 *   <li>8081 - HTTP/1.1 over TLS, no ALPN advertised</li>
 *   <li>8082 - HTTP/2 cleartext, prior-knowledge</li>
 *   <li>8443 - HTTP/2 over TLS, ALPN {@code h2}</li>
 * </ul>
 * Each listener gets its own {@link NioConfig}: the application-protocol list lives on
 * the config, so a shared instance would let the last listener's ALPN overwrite the
 * others'. Only one port carries load at a time, so each one keeps a full worker pool.
 */
public final class Main {

    private static final String CERT_FILE = "/certs/server.crt";
    private static final String KEY_FILE = "/certs/server.key";
    private static final String STATIC_DIR = "/data/static";

    public static void main(String[] args) {
        AnnotationRouterHandler router = new AnnotationRouterHandler()
                .messageConverter(new JsonMessageConverter())
                .scanPackages("com.httparena");

        // Static files go through the framework's own resource handler.
        router.resource(new HttpResourceRoute("/static", STATIC_DIR).detectPreCompressed(true));

        NioConfig h1 = config();
        HTTPServer.of(8080, h1).requestHandler(router).start();

        NioConfig h1Tls = config();
        HTTPServer.of(8081, h1Tls)
                .pemSSL(CERT_FILE, KEY_FILE)
                .requestHandler(router)
                .start();

        NioConfig h2c = config();
        HTTPServer.of(8082, h2c)
                .applicationProtocols("h2c")
                .requestHandler(router)
                .start();

        NioConfig h2 = config();
        HTTPServer.of(8443, h2)
                .pemSSL(CERT_FILE, KEY_FILE)
                .h2()
                .requestHandler(router)
                .start();
    }

    private static NioConfig config() {
        NioConfig nioConfig = new NioConfig().testMode(); // testMode includes HTTP/1.1 pipelining
        nioConfig.option(HttpOptions.GZIP, true);

        // Clear text scenes, especially pipeline, improve performance
        nioConfig.setReadBufferSize(16384);
        nioConfig.setWriteBufferSize(16384);
        return nioConfig;
    }
}
