package com.httparena;

import io.vertx.core.buffer.Buffer;
import io.vertx.ext.web.Router;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/**
 * Serves the static resources in /data/static with pre-compressed variants.
 */
@ApplicationScoped
public class StaticFiles {

    private record StaticEntry(byte[] data, byte[] br, byte[] gz, String contentType) {}

    private static final Map<String, String> MIME_TYPES = Map.of(
        ".css", "text/css", ".js", "application/javascript", ".html", "text/html",
        ".woff2", "font/woff2", ".svg", "image/svg+xml", ".webp", "image/webp", ".json", "application/json"
    );

    void init(@Observes Router router) {
        var staticDir = new File("/data/static");
        var cache = new HashMap<String, StaticEntry>();

        if (staticDir.isDirectory()) {
            var files = staticDir.listFiles();
            if (files != null) {
                for (var file : files) {
                    var name = file.getName();
                    if (name.endsWith(".br") || name.endsWith(".gz")) continue;
                    if (!file.isFile()) continue;
                    try {
                        var data = Files.readAllBytes(file.toPath());
                        var ext = name.contains(".") ? name.substring(name.lastIndexOf(".")) : "";
                        var ct = MIME_TYPES.getOrDefault(ext, "application/octet-stream");
                        var brPath = Path.of(file.getPath() + ".br");
                        var gzPath = Path.of(file.getPath() + ".gz");
                        byte[] br = java.nio.file.Files.exists(brPath) ? Files.readAllBytes(brPath) : null;
                        byte[] gz = java.nio.file.Files.exists(gzPath) ? Files.readAllBytes(gzPath) : null;
                        cache.put(name, new StaticEntry(data, br, gz, ct));
                    } catch (IOException ignored) {}
                }
            }
        }

        router.get("/static/:filename").handler(ctx -> {
            var filename = ctx.pathParam("filename");
            var entry = cache.get(filename);
            if (entry == null) {
                ctx.response().setStatusCode(404).end("Not found");
                return;
            }
            var ae = ctx.request().getHeader("Accept-Encoding");
            if (ae == null) ae = "";
            ctx.response().putHeader("Content-Type", entry.contentType());
            if (entry.br() != null && ae.contains("br")) {
                ctx.response().putHeader("Content-Encoding", "br");
                ctx.response().end(Buffer.buffer(entry.br()));
            } else if (entry.gz() != null && ae.contains("gzip")) {
                ctx.response().putHeader("Content-Encoding", "gzip");
                ctx.response().end(Buffer.buffer(entry.gz()));
            } else {
                ctx.response().end(Buffer.buffer(entry.data()));
            }
        });
    }

}
