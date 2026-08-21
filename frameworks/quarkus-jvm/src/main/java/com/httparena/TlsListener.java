package com.httparena;

import io.quarkus.runtime.StartupEvent;
import io.vertx.core.Vertx;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.core.net.PemKeyCertOptions;
import io.vertx.ext.web.Router;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.inject.Inject;

import java.io.File;

/**
 * json-tls and static-tls: HTTP/1.1 over TLS on 8081.
 *
 * Quarkus binds one TLS port (quarkus.http.ssl-port, 8443 here) and the h2
 * profiles have it, so the second listener is opened directly on Vert.x and
 * handed the application's own Router - the same routes, JAX-RS resources
 * included, rather than a second copy of the handlers.
 *
 * ALPN is off on purpose: those two profiles want HTTP/1.1 negotiated and no
 * h2 offered. The harness only mounts /certs for the TLS profiles, so without
 * them this listener is not opened.
 */
@ApplicationScoped
public class TlsListener {

    private static final String CERT = "/certs/server.crt";
    private static final String KEY = "/certs/server.key";
    private static final int PORT = 8081;

    @Inject
    Vertx vertx;

    @Inject
    Router router;

    void onStart(@Observes StartupEvent event) {
        if (!new File(CERT).isFile() || !new File(KEY).isFile()) return;

        var options = new HttpServerOptions()
            .setPort(PORT)
            .setHost("0.0.0.0")
            .setSsl(true)
            .setUseAlpn(false)
            .setPemKeyCertOptions(new PemKeyCertOptions().setCertPath(CERT).setKeyPath(KEY));

        vertx.createHttpServer(options).requestHandler(router).listen();
    }
}
