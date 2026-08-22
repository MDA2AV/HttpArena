package com.httparena;

import io.vertx.ext.web.Router;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;

import java.io.File;
import java.util.Map;

/**
 * Serves the static resources in /data/static, choosing a pre-compressed
 * sibling when the client accepts one.
 *
 * Every request reaches the disk. The profile requires it of every type -
 * "no in-memory caching, no memory-mapped files, no pre-loaded file buffers" -
 * because moving bytes off disk is the workload it exists to measure. This used
 * to read all twenty files, and their .br and .gz variants, into a HashMap at
 * startup and answer out of memory, which measured something else entirely.
 *
 * sendFile() hands the descriptor to the kernel rather than reading the bytes
 * into the JVM first, which is the normal way Vert.x serves a file and keeps
 * nothing between requests.
 */
@ApplicationScoped
public class StaticFiles {

    private static final String ROOT = "/data/static";

    private static final Map<String, String> MIME_TYPES = Map.of(
        ".css", "text/css", ".js", "application/javascript", ".html", "text/html",
        ".woff2", "font/woff2", ".svg", "image/svg+xml", ".webp", "image/webp", ".json", "application/json"
    );

    void init(@Observes Router router) {
        router.get("/static/:filename").handler(ctx -> {
            var filename = ctx.pathParam("filename");
            // No traversal out of the mount, and no directory reads.
            if (filename.isEmpty() || filename.contains("/") || filename.contains("..")) {
                ctx.response().setStatusCode(404).end("Not found");
                return;
            }

            var ext = filename.contains(".") ? filename.substring(filename.lastIndexOf(".")) : "";
            var contentType = MIME_TYPES.getOrDefault(ext, "application/octet-stream");

            var ae = ctx.request().getHeader("Accept-Encoding");
            if (ae == null) ae = "";

            // The .br and .gz files the harness leaves beside the originals are
            // still served, but they are looked at on disk per request like the
            // identity file rather than held from startup.
            String path = ROOT + "/" + filename;
            String encoding = null;
            if (ae.contains("br") && new File(path + ".br").isFile()) {
                path = path + ".br";
                encoding = "br";
            } else if (ae.contains("gzip") && new File(path + ".gz").isFile()) {
                path = path + ".gz";
                encoding = "gzip";
            } else if (!new File(path).isFile()) {
                ctx.response().setStatusCode(404).end("Not found");
                return;
            }

            ctx.response().putHeader("Content-Type", contentType);
            if (encoding != null) ctx.response().putHeader("Content-Encoding", encoding);
            ctx.response().sendFile(path);
        });
    }
}
