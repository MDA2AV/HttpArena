// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.http.Get;
import dev.cardigan.http.HttpRequest;
import dev.cardigan.http.Response;
import dev.cardigan.http.ResponseHeaders;
import dev.cardigan.http.StaticBody;
import dev.cardigan.http.Utf8Slice;

import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.file.Files;
import java.nio.file.Path;

/** Preloads the fixed HttpArena static corpus into Cardigan native bodies. */
public final class HttpArenaStaticController {
    private static final ResponseHeaders VARY_ENCODING =
        ResponseHeaders.of("vary", "Accept-Encoding");
    private static final ResponseHeaders BROTLI_ENCODING =
        ResponseHeaders.builder()
            .add("content-encoding", "br")
            .add("vary", "Accept-Encoding")
            .build();

    private final StaticAsset resetCss;
    private final StaticAsset layoutCss;
    private final StaticAsset themeCss;
    private final StaticAsset componentsCss;
    private final StaticAsset utilitiesCss;
    private final StaticAsset analyticsJs;
    private final StaticAsset helpersJs;
    private final StaticAsset appJs;
    private final StaticAsset vendorJs;
    private final StaticAsset routerJs;
    private final StaticAsset headerHtml;
    private final StaticAsset footerHtml;
    private final StaticAsset regularWoff2;
    private final StaticAsset boldWoff2;
    private final StaticAsset logoSvg;
    private final StaticAsset iconSpriteSvg;
    private final StaticAsset heroWebp;
    private final StaticAsset thumb1Webp;
    private final StaticAsset thumb2Webp;
    private final StaticAsset manifestJson;

    HttpArenaStaticController(Path directory) throws IOException {
        resetCss = load(directory, "reset.css", "text/css");
        layoutCss = load(directory, "layout.css", "text/css");
        themeCss = load(directory, "theme.css", "text/css");
        componentsCss = load(directory, "components.css", "text/css");
        utilitiesCss = load(directory, "utilities.css", "text/css");
        analyticsJs = load(
            directory, "analytics.js", "application/javascript");
        helpersJs = load(
            directory, "helpers.js", "application/javascript");
        appJs = load(directory, "app.js", "application/javascript");
        vendorJs = load(directory, "vendor.js", "application/javascript");
        routerJs = load(directory, "router.js", "application/javascript");
        headerHtml = load(directory, "header.html", "text/html");
        footerHtml = load(directory, "footer.html", "text/html");
        regularWoff2 = load(directory, "regular.woff2", "font/woff2");
        boldWoff2 = load(directory, "bold.woff2", "font/woff2");
        logoSvg = load(directory, "logo.svg", "image/svg+xml");
        iconSpriteSvg = load(
            directory, "icon-sprite.svg", "image/svg+xml");
        heroWebp = load(directory, "hero.webp", "image/webp");
        thumb1Webp = load(directory, "thumb1.webp", "image/webp");
        thumb2Webp = load(directory, "thumb2.webp", "image/webp");
        manifestJson = load(
            directory, "manifest.json", "application/json");
    }

    @Get("/static/reset.css")
    public Response resetCss(HttpRequest request) {
        return resetCss.select(request);
    }

    @Get("/static/layout.css")
    public Response layoutCss(HttpRequest request) {
        return layoutCss.select(request);
    }

    @Get("/static/theme.css")
    public Response themeCss(HttpRequest request) {
        return themeCss.select(request);
    }

    @Get("/static/components.css")
    public Response componentsCss(HttpRequest request) {
        return componentsCss.select(request);
    }

    @Get("/static/utilities.css")
    public Response utilitiesCss(HttpRequest request) {
        return utilitiesCss.select(request);
    }

    @Get("/static/analytics.js")
    public Response analyticsJs(HttpRequest request) {
        return analyticsJs.select(request);
    }

    @Get("/static/helpers.js")
    public Response helpersJs(HttpRequest request) {
        return helpersJs.select(request);
    }

    @Get("/static/app.js")
    public Response appJs(HttpRequest request) {
        return appJs.select(request);
    }

    @Get("/static/vendor.js")
    public Response vendorJs(HttpRequest request) {
        return vendorJs.select(request);
    }

    @Get("/static/router.js")
    public Response routerJs(HttpRequest request) {
        return routerJs.select(request);
    }

    @Get("/static/header.html")
    public Response headerHtml(HttpRequest request) {
        return headerHtml.select(request);
    }

    @Get("/static/footer.html")
    public Response footerHtml(HttpRequest request) {
        return footerHtml.select(request);
    }

    @Get("/static/regular.woff2")
    public Response regularWoff2(HttpRequest request) {
        return regularWoff2.select(request);
    }

    @Get("/static/bold.woff2")
    public Response boldWoff2(HttpRequest request) {
        return boldWoff2.select(request);
    }

    @Get("/static/logo.svg")
    public Response logoSvg(HttpRequest request) {
        return logoSvg.select(request);
    }

    @Get("/static/icon-sprite.svg")
    public Response iconSpriteSvg(HttpRequest request) {
        return iconSpriteSvg.select(request);
    }

    @Get("/static/hero.webp")
    public Response heroWebp(HttpRequest request) {
        return heroWebp.select(request);
    }

    @Get("/static/thumb1.webp")
    public Response thumb1Webp(HttpRequest request) {
        return thumb1Webp.select(request);
    }

    @Get("/static/thumb2.webp")
    public Response thumb2Webp(HttpRequest request) {
        return thumb2Webp.select(request);
    }

    @Get("/static/manifest.json")
    public Response manifestJson(HttpRequest request) {
        return manifestJson.select(request);
    }

    private static StaticAsset load(
            Path directory, String filename, String contentType)
            throws IOException {
        Path identityPath = directory.resolve(filename);
        Response identity = response(identityPath, contentType);
        Path brotliPath = directory.resolve(filename + ".br");
        if (!Files.isRegularFile(brotliPath)) {
            return new StaticAsset(identity, null);
        }
        return new StaticAsset(
            identity.withHeaders(VARY_ENCODING),
            response(brotliPath, contentType).withHeaders(BROTLI_ENCODING));
    }

    private static Response response(Path path, String contentType)
            throws IOException {
        return new Response(
            200, contentType,
            StaticBody.copyOf(Files.readAllBytes(path)));
    }

    static boolean acceptsBrotli(Utf8Slice value) {
        if (value == null || value.length() == 0) {
            return false;
        }
        MemorySegment bytes = value.segment();
        long cursor = value.offset();
        long end = cursor + value.length();
        int explicit = -1;
        int wildcard = -1;
        while (cursor < end) {
            cursor = skipDelimiters(bytes, cursor, end);
            long tokenStart = cursor;
            while (cursor < end && isToken(byteAt(bytes, cursor))) {
                cursor++;
            }
            long tokenEnd = cursor;
            int quality = 1_000;
            while (cursor < end && byteAt(bytes, cursor) != ',') {
                cursor = skipWhitespace(bytes, cursor, end);
                if (cursor >= end || byteAt(bytes, cursor) == ',') {
                    break;
                }
                if (byteAt(bytes, cursor) != ';') {
                    cursor++;
                    continue;
                }
                cursor = skipWhitespace(bytes, cursor + 1, end);
                long nameStart = cursor;
                while (cursor < end && isToken(byteAt(bytes, cursor))) {
                    cursor++;
                }
                long nameEnd = cursor;
                cursor = skipWhitespace(bytes, cursor, end);
                if (cursor >= end || byteAt(bytes, cursor) != '=') {
                    continue;
                }
                cursor = skipWhitespace(bytes, cursor + 1, end);
                long parameterStart = cursor;
                while (cursor < end) {
                    byte current = byteAt(bytes, cursor);
                    if (current == ';' || current == ',') {
                        break;
                    }
                    cursor++;
                }
                long parameterEnd = trimWhitespace(
                    bytes, parameterStart, cursor);
                if (equalsIgnoreCase(
                        bytes, nameStart, nameEnd, "q")) {
                    quality = parseQuality(
                        bytes, parameterStart, parameterEnd);
                }
            }
            if (equalsIgnoreCase(bytes, tokenStart, tokenEnd, "br")) {
                explicit = Math.max(explicit, quality);
            } else if (tokenEnd - tokenStart == 1
                    && byteAt(bytes, tokenStart) == '*') {
                wildcard = Math.max(wildcard, quality);
            }
            if (cursor < end) {
                cursor++;
            }
        }
        return explicit >= 0 ? explicit != 0 : wildcard > 0;
    }

    private static int parseQuality(
            MemorySegment bytes, long start, long end) {
        if (start >= end) {
            return 0;
        }
        byte whole = byteAt(bytes, start++);
        if (whole != '0' && whole != '1') {
            return 0;
        }
        int quality = whole == '1' ? 1_000 : 0;
        if (start == end) {
            return quality;
        }
        if (byteAt(bytes, start++) != '.' || end - start > 3) {
            return 0;
        }
        int place = 100;
        while (start < end) {
            byte digit = byteAt(bytes, start++);
            if (digit < '0' || digit > '9'
                    || whole == '1' && digit != '0') {
                return 0;
            }
            quality += (digit - '0') * place;
            place /= 10;
        }
        return quality;
    }

    private static long skipDelimiters(
            MemorySegment bytes, long cursor, long end) {
        while (cursor < end) {
            byte current = byteAt(bytes, cursor);
            if (current != ',' && current != ' ' && current != '\t') {
                break;
            }
            cursor++;
        }
        return cursor;
    }

    private static long skipWhitespace(
            MemorySegment bytes, long cursor, long end) {
        while (cursor < end) {
            byte current = byteAt(bytes, cursor);
            if (current != ' ' && current != '\t') {
                break;
            }
            cursor++;
        }
        return cursor;
    }

    private static long trimWhitespace(
            MemorySegment bytes, long start, long end) {
        while (end > start) {
            byte current = byteAt(bytes, end - 1);
            if (current != ' ' && current != '\t') {
                break;
            }
            end--;
        }
        return end;
    }

    private static boolean equalsIgnoreCase(
            MemorySegment bytes, long start, long end, String expected) {
        if (end - start != expected.length()) {
            return false;
        }
        for (int index = 0; index < expected.length(); index++) {
            int actual = byteAt(bytes, start + index);
            if (actual >= 'A' && actual <= 'Z') {
                actual += 'a' - 'A';
            }
            if (actual != expected.charAt(index)) {
                return false;
            }
        }
        return true;
    }

    private static boolean isToken(byte value) {
        return value > 0x20 && value < 0x7f
            && switch (value) {
                case '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"',
                     '/', '[', ']', '?', '=', '{', '}' -> false;
                default -> true;
            };
    }

    private static byte byteAt(MemorySegment bytes, long offset) {
        return bytes.get(ValueLayout.JAVA_BYTE, offset);
    }

    private record StaticAsset(Response identity, Response brotli) {
        Response select(HttpRequest request) {
            if (brotli == null) {
                return identity;
            }
            return acceptsBrotli(request.getHeader("Accept-Encoding"))
                ? brotli : identity;
        }
    }
}
