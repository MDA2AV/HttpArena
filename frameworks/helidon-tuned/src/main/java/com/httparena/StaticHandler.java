package com.httparena;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;
import java.util.Map;

import io.helidon.http.Header;
import io.helidon.http.HeaderNames;
import io.helidon.http.HeaderValues;
import io.helidon.http.Status;
import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import static com.httparena.Main.SERVER_HEADER;

class StaticHandler implements Handler {
    private static final Header VARY_ACCEPT_ENCODING =
            HeaderValues.createCached(HeaderNames.VARY, HeaderNames.ACCEPT_ENCODING_NAME);
    private static final Header CONTENT_ENCODING_BR =
            HeaderValues.createCached(HeaderNames.CONTENT_ENCODING, "br");
    private static final Header CONTENT_ENCODING_GZIP =
            HeaderValues.createCached(HeaderNames.CONTENT_ENCODING, "gzip");
    private static final Header CONTENT_TYPE_OCTET_STREAM =
            HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "application/octet-stream");
    private static final Map<String, Header> CONTENT_TYPES = Map.of(
            ".css", HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "text/css"),
            ".js", HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "application/javascript"),
            ".html", HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "text/html"),
            ".woff2", HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "font/woff2"),
            ".svg", HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "image/svg+xml"),
            ".webp", HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "image/webp"),
            ".json", HeaderValues.createCached(HeaderNames.CONTENT_TYPE, "application/json")
    );

    private final Path staticDir;

    StaticHandler(String dataLocation) throws IOException {
        this.staticDir = Path.of(dataLocation, "static").toAbsolutePath().normalize();
        if (!Files.isDirectory(staticDir)) {
            throw new IllegalArgumentException("Failed to load static assets from: "
                                                       + staticDir);
        }
    }

    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        String filename = req.path().pathParameters().first("filename").orElse("");
        Path rawPath = resolveStaticPath(filename);
        if (rawPath == null || !Files.isRegularFile(rawPath)) {
            res.status(Status.NOT_FOUND_404)
                    .header(SERVER_HEADER)
                    .send();
            return;
        }

        res.header(SERVER_HEADER);
        res.header(VARY_ACCEPT_ENCODING);
        res.header(contentType(filename));

        String acceptEncoding = req.headers()
                .first(HeaderNames.ACCEPT_ENCODING)
                .orElse("")
                .toLowerCase(Locale.ROOT);
        try {
            if (acceptEncoding.contains("br")) {
                Path brPath = encodedSibling(rawPath, ".br");
                if (Files.isRegularFile(brPath)) {
                    res.header(CONTENT_ENCODING_BR);
                    res.send(Files.readAllBytes(brPath));
                    return;
                }
            }
            if (acceptEncoding.contains("gzip")) {
                Path gzPath = encodedSibling(rawPath, ".gz");
                if (Files.isRegularFile(gzPath)) {
                    res.header(CONTENT_ENCODING_GZIP);
                    res.send(Files.readAllBytes(gzPath));
                    return;
                }
            }
            res.send(Files.readAllBytes(rawPath));
        } catch (IOException e) {
            res.status(Status.INTERNAL_SERVER_ERROR_500)
                    .header(SERVER_HEADER)
                    .send();
        }
    }

    private Path resolveStaticPath(String fileName) {
        if (fileName.isEmpty()) {
            return null;
        }
        Path resolved = staticDir.resolve(fileName).normalize();
        if (!resolved.startsWith(staticDir)) {
            return null;
        }
        return resolved;
    }

    private static Path encodedSibling(Path rawPath, String suffix) {
        return rawPath.resolveSibling(rawPath.getFileName() + suffix);
    }

    private static Header contentType(String fileName) {
        int dotIndex = fileName.lastIndexOf('.');
        if (dotIndex < 0) {
            return CONTENT_TYPE_OCTET_STREAM;
        }
        return CONTENT_TYPES.getOrDefault(fileName.substring(dotIndex), CONTENT_TYPE_OCTET_STREAM);
    }

}
