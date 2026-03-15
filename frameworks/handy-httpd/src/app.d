module app;

import handy_httpd;
import handy_httpd.handlers.path_handler;
import d2sqlite3;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : round;
import std.file : read, readText, dirEntries, SpanMode;
import std.path : extension;
import std.string : strip;
import std.algorithm : splitter;
import std.zlib : Compress, HeaderFormat;

private enum SERVER_NAME = "handy-httpd";

// --- Data types ---

struct Rating {
    double score;
    long count;
}

struct DatasetItem {
    long id;
    string name;
    string category;
    double price;
    long quantity;
    bool active;
    string[] tags;
    Rating rating;
}

// --- Global state ---

private __gshared DatasetItem[] dataset;
private __gshared ubyte[] jsonLargeCache;
private __gshared ubyte[][string] staticFiles;
private __gshared string[string] staticContentTypes;

// --- Helpers ---

DatasetItem[] loadDataset(string path) {
    DatasetItem[] items;
    try {
        string data = readText(path);
        JSONValue arr = parseJSON(data);
        foreach (ref item; arr.array) {
            DatasetItem d;
            d.id = item["id"].get!long;
            d.name = item["name"].str;
            d.category = item["category"].str;
            d.price = item["price"].type == JSONType.integer
                ? cast(double) item["price"].get!long
                : item["price"].get!double;
            d.quantity = item["quantity"].get!long;
            d.active = item["active"].type == JSONType.true_;
            foreach (ref t; item["tags"].array)
                d.tags ~= t.str;
            d.rating.score = item["rating"]["score"].type == JSONType.integer
                ? cast(double) item["rating"]["score"].get!long
                : item["rating"]["score"].get!double;
            d.rating.count = item["rating"]["count"].get!long;
            items ~= d;
        }
    } catch (Exception e) {}
    return items;
}

JSONValue buildJsonResponse(const DatasetItem[] items) {
    JSONValue[] jsonItems;
    foreach (ref d; items) {
        JSONValue item = JSONValue(string[string].init);
        item["id"] = JSONValue(d.id);
        item["name"] = JSONValue(d.name);
        item["category"] = JSONValue(d.category);
        item["price"] = JSONValue(d.price);
        item["quantity"] = JSONValue(d.quantity);
        item["active"] = JSONValue(d.active);
        JSONValue[] tagsArr;
        foreach (ref t; d.tags)
            tagsArr ~= JSONValue(t);
        item["tags"] = JSONValue(tagsArr);
        JSONValue rat = JSONValue(string[string].init);
        rat["score"] = JSONValue(d.rating.score);
        rat["count"] = JSONValue(d.rating.count);
        item["rating"] = rat;
        item["total"] = JSONValue(round(d.price * cast(double) d.quantity * 100.0) / 100.0);
        jsonItems ~= item;
    }
    JSONValue resp = JSONValue(string[string].init);
    resp["items"] = JSONValue(jsonItems);
    resp["count"] = JSONValue(cast(long) jsonItems.length);
    return resp;
}

long parseQuerySum(string query) {
    long sum = 0;
    foreach (pair; query.splitter('&')) {
        import std.algorithm : findSplitAfter;
        auto parts = pair.findSplitAfter("=");
        if (parts[1].length > 0) {
            try {
                sum += parts[1].to!long;
            } catch (Exception e) {}
        }
    }
    return sum;
}

void loadStaticFiles() {
    immutable string[string] mimeTypes = [
        ".css": "text/css",
        ".js": "application/javascript",
        ".html": "text/html",
        ".woff2": "font/woff2",
        ".svg": "image/svg+xml",
        ".webp": "image/webp",
        ".json": "application/json",
    ];
    try {
        foreach (entry; dirEntries("/data/static", SpanMode.shallow)) {
            import std.path : baseName;
            string name = baseName(entry.name);
            string ext = extension(name);
            string ct = ext in mimeTypes ? mimeTypes[ext] : "application/octet-stream";
            staticFiles[name] = cast(ubyte[]) read(entry.name);
            staticContentTypes[name] = ct;
        }
    } catch (Exception e) {}
}

// --- Chunked TE decoder ---

string decodeChunkedPayload(string raw) {
    string result;
    size_t pos = 0;
    while (pos < raw.length) {
        // Find the end of the chunk size line
        size_t lineEnd = pos;
        while (lineEnd < raw.length && raw[lineEnd] != '\r' && raw[lineEnd] != '\n')
            lineEnd++;
        if (lineEnd == pos) break;
        string sizeStr = raw[pos .. lineEnd].strip();
        long chunkSize;
        try {
            chunkSize = sizeStr.to!long(16);
        } catch (Exception e) {
            break;
        }
        if (chunkSize == 0) break;
        // Skip past \r\n
        pos = lineEnd;
        if (pos < raw.length && raw[pos] == '\r') pos++;
        if (pos < raw.length && raw[pos] == '\n') pos++;
        // Read chunk data
        size_t end = pos + cast(size_t) chunkSize;
        if (end > raw.length) end = raw.length;
        result ~= raw[pos .. end];
        pos = end;
        // Skip trailing \r\n
        if (pos < raw.length && raw[pos] == '\r') pos++;
        if (pos < raw.length && raw[pos] == '\n') pos++;
    }
    return result;
}

ubyte[] decodeChunkedBytes(ubyte[] raw) {
    ubyte[] result;
    size_t pos = 0;
    while (pos < raw.length) {
        size_t lineEnd = pos;
        while (lineEnd < raw.length && raw[lineEnd] != '\r' && raw[lineEnd] != '\n')
            lineEnd++;
        if (lineEnd == pos) break;
        string sizeStr = (cast(string) raw[pos .. lineEnd]).strip();
        long chunkSize;
        try {
            chunkSize = sizeStr.to!long(16);
        } catch (Exception e) {
            break;
        }
        if (chunkSize == 0) break;
        pos = lineEnd;
        if (pos < raw.length && raw[pos] == '\r') pos++;
        if (pos < raw.length && raw[pos] == '\n') pos++;
        size_t end = pos + cast(size_t) chunkSize;
        if (end > raw.length) end = raw.length;
        result ~= raw[pos .. end];
        pos = end;
        if (pos < raw.length && raw[pos] == '\r') pos++;
        if (pos < raw.length && raw[pos] == '\n') pos++;
    }
    return result;
}

// --- Route handlers ---

void pipelineHandler(ref HttpRequestContext ctx) {
    ctx.response.addHeader("Server", SERVER_NAME);
    ctx.response.writeBodyString("ok", "text/plain");
}

void baseline11Handler(ref HttpRequestContext ctx) {
    long sum = 0;

    // Parse query params from the request
    foreach (key, value; ctx.request.queryParams) {
        try {
            sum += value.to!long;
        } catch (Exception e) {}
    }

    // If POST, also read body (handle both regular and chunked TE)
    if (ctx.request.method == Method.POST) {
        try {
            string rawBody = ctx.request.readBodyAsString().strip();
            if (rawBody.length > 0) {
                // Try parsing directly first (works if library already decoded chunked TE)
                bool parsed = false;
                try {
                    sum += rawBody.to!long;
                    parsed = true;
                } catch (Exception e) {}
                // If direct parse failed and chunked TE, try decoding chunk framing
                if (!parsed) {
                    string te = ctx.request.headers.getFirst("Transfer-Encoding").orElse("");
                    import std.algorithm : canFind;
                    if (te.canFind("chunked")) {
                        string decoded = decodeChunkedPayload(rawBody).strip();
                        if (decoded.length > 0)
                            sum += decoded.to!long;
                    }
                }
            }
        } catch (Exception e) {}
    }

    ctx.response.addHeader("Server", SERVER_NAME);
    ctx.response.writeBodyString(sum.to!string, "text/plain");
}

void baseline2Handler(ref HttpRequestContext ctx) {
    long sum = 0;
    foreach (key, value; ctx.request.queryParams) {
        try {
            sum += value.to!long;
        } catch (Exception e) {}
    }
    ctx.response.addHeader("Server", SERVER_NAME);
    ctx.response.writeBodyString(sum.to!string, "text/plain");
}

void jsonHandler(ref HttpRequestContext ctx) {
    if (dataset.length == 0) {
        ctx.response.setStatus(HttpStatus.INTERNAL_SERVER_ERROR);
        ctx.response.writeBodyString("No dataset", "text/plain");
        return;
    }
    JSONValue resp = buildJsonResponse(dataset);
    ctx.response.addHeader("Server", SERVER_NAME);
    ctx.response.writeBodyString(resp.toString(), "application/json");
}

void compressionHandler(ref HttpRequestContext ctx) {
    // Check if client accepts gzip
    string acceptEncoding = ctx.request.headers.getFirst("Accept-Encoding").orElse("");
    import std.algorithm : canFind;
    if (acceptEncoding.canFind("gzip") && jsonLargeCache.length > 0) {
        auto compress = new Compress(6, HeaderFormat.gzip);
        auto compressed = compress.compress(jsonLargeCache);
        compressed ~= compress.flush();
        ctx.response.addHeader("Server", SERVER_NAME);
        ctx.response.addHeader("Content-Encoding", "gzip");
        ctx.response.writeBodyBytes(cast(ubyte[]) compressed, "application/json");
    } else {
        ctx.response.addHeader("Server", SERVER_NAME);
        ctx.response.writeBodyBytes(jsonLargeCache, "application/json");
    }
}

void uploadHandler(ref HttpRequestContext ctx) {
    ubyte[] rawBody = ctx.request.readBodyAsBytes();
    ubyte[] body;
    string te = ctx.request.headers.getFirst("Transfer-Encoding").orElse("");
    import std.algorithm : canFind;
    if (te.canFind("chunked") && rawBody.length > 0) {
        // Try chunked decode; if result is empty, library may have already decoded
        body = decodeChunkedBytes(rawBody);
        if (body.length == 0) body = rawBody;
    } else {
        body = rawBody;
    }
    ctx.response.addHeader("Server", SERVER_NAME);
    ctx.response.writeBodyString(body.length.to!string, "text/plain");
}

void dbHandler(ref HttpRequestContext ctx) {
    double minPrice = 10.0;
    double maxPrice = 50.0;

    auto minStr = ctx.request.queryParams.getFirst("min");
    if (!minStr.isNull) {
        try { minPrice = minStr.value.to!double; } catch (Exception e) {}
    }
    auto maxStr = ctx.request.queryParams.getFirst("max");
    if (!maxStr.isNull) {
        try { maxPrice = maxStr.value.to!double; } catch (Exception e) {}
    }

    try {
        auto db = Database("/data/benchmark.db", SQLITE_OPEN_READONLY);
        auto stmt = db.prepare(
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50"
        );
        stmt.bind(1, minPrice);
        stmt.bind(2, maxPrice);

        JSONValue[] items;
        foreach (row; stmt.execute()) {
            JSONValue item = JSONValue(string[string].init);
            item["id"] = JSONValue(row.peek!long(0));
            item["name"] = JSONValue(row.peek!string(1));
            item["category"] = JSONValue(row.peek!string(2));
            item["price"] = JSONValue(row.peek!double(3));
            item["quantity"] = JSONValue(row.peek!long(4));
            item["active"] = JSONValue(row.peek!long(5) == 1);
            try {
                item["tags"] = parseJSON(row.peek!string(6));
            } catch (Exception e) {
                item["tags"] = JSONValue((JSONValue[]).init);
            }
            JSONValue rat = JSONValue(string[string].init);
            rat["score"] = JSONValue(row.peek!double(7));
            rat["count"] = JSONValue(row.peek!long(8));
            item["rating"] = rat;
            items ~= item;
        }

        JSONValue result = JSONValue(string[string].init);
        result["items"] = JSONValue(items);
        result["count"] = JSONValue(cast(long) items.length);

        ctx.response.addHeader("Server", SERVER_NAME);
        ctx.response.writeBodyString(result.toString(), "application/json");
    } catch (Exception e) {
        ctx.response.setStatus(HttpStatus.INTERNAL_SERVER_ERROR);
        ctx.response.writeBodyString("Database error", "text/plain");
    }
}

void staticHandler(ref HttpRequestContext ctx) {
    string filename = ctx.request.getPathParamAs!string("filename");
    if (filename in staticFiles) {
        ctx.response.addHeader("Server", SERVER_NAME);
        ctx.response.writeBodyBytes(staticFiles[filename], staticContentTypes[filename]);
    } else {
        ctx.response.setStatus(HttpStatus.NOT_FOUND);
        ctx.response.writeBodyString("Not found", "text/plain");
    }
}

// --- Main ---

void main() {
    import std.process : environment;

    // Load data
    string datasetPath = environment.get("DATASET_PATH", "/data/dataset.json");
    dataset = loadDataset(datasetPath);

    // Load large dataset for compression endpoint
    auto largeDataset = loadDataset("/data/dataset-large.json");
    if (largeDataset.length > 0) {
        JSONValue largeResp = buildJsonResponse(largeDataset);
        string largeJson = largeResp.toString();
        jsonLargeCache = cast(ubyte[]) largeJson.dup;
    }

    // Load static files
    loadStaticFiles();

    // Set up routes
    auto router = new PathHandler();
    router.addMapping(Method.GET, "/pipeline", &pipelineHandler);
    router.addMapping(Method.GET, "/baseline11", &baseline11Handler);
    router.addMapping(Method.POST, "/baseline11", &baseline11Handler);
    router.addMapping(Method.GET, "/baseline2", &baseline2Handler);
    router.addMapping(Method.GET, "/json", &jsonHandler);
    router.addMapping(Method.GET, "/compression", &compressionHandler);
    router.addMapping(Method.POST, "/upload", &uploadHandler);
    router.addMapping(Method.GET, "/db", &dbHandler);
    router.addMapping(Method.GET, "/static/:filename", &staticHandler);

    // Configure server
    ServerConfig cfg;
    cfg.port = 8080;
    cfg.hostname = "0.0.0.0";
    cfg.connectionQueueSize = 4096;
    cfg.receiveBufferSize = 16384;

    import core.cpuid : threadsPerCPU;
    auto cpus = threadsPerCPU();
    if (cpus > 0)
        cfg.workerPoolSize = cpus;
    else
        cfg.workerPoolSize = 4;

    auto server = new HttpServer(router, cfg);
    server.start();
}
