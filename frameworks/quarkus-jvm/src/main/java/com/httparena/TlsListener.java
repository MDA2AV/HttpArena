package com.httparena;

import io.quarkus.runtime.StartupEvent;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.DeploymentOptions;
import io.vertx.core.Promise;
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
 * The server is deployed as a verticle with one instance per core. A single
 * createHttpServer().listen() binds to whichever event loop created it, so all
 * TLS handshakes and requests for the port would run on one thread while the
 * other 31 sit idle; the ports Quarkus binds itself are spread across every
 * event loop. Vert.x shares the bound port between the instances and hands
 * accepted connections out round-robin, which restores that.
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

        var deployment = new DeploymentOptions()
            .setInstances(Runtime.getRuntime().availableProcessors());

        vertx.deployVerticle(() -> new TlsServer(router), deployment);
    }

    private static final class TlsServer extends AbstractVerticle {

        private final Router router;

        private TlsServer(Router router) {
            this.router = router;
        }

        @Override
        public void start(Promise<Void> started) {
            var options = new HttpServerOptions()
                .setPort(PORT)
                .setHost("0.0.0.0")
                .setSsl(true)
                .setUseAlpn(false)
                .setPemKeyCertOptions(new PemKeyCertOptions().setCertPath(CERT).setKeyPath(KEY));

            vertx.createHttpServer(options)
                .requestHandler(router)
                .listen()
                .<Void>mapEmpty()
                .onComplete(started);
        }
    }
}
