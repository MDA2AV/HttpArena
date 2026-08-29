module app;

import vibe.core.core : runApplication, runWorkerTaskDist, setupWorkerThreads;
import vibe.core.log : logInfo, logWarn;
import vibe.data.json : deserializeJson, parseJsonString;
import vibe.data.serialization : optional;
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.stream.operations : readAll, readAllUTF8;
import vibe.stream.tls : createTLSContext, TLSContext, TLSContextKind;

import std.algorithm.comparison : min;
import std.conv : to;

// json-tls listens here; 8080 stays plaintext and 8443 belongs to h2/h3.
enum H1TLS_PORT = 8081;

struct Rating {
    long score;
    long count;
}

// Member order is the wire order of the serializer: id, name, category, price,
// quantity, active, tags, rating, total.
struct Item {
    long id;
    string name;
    string category;
    long price;
    long quantity;
    bool active;
    string[] tags;
    Rating rating;
    @optional long total;
}

struct ItemList {
    Item[] items;
    long count;
}

// Read once before the workers start, then only read from the request handlers,
// so every thread shares the one copy without locking.
__gshared Item[] g_dataset;

@property Item[] dataset()
@trusted nothrow @nogc { return g_dataset; }

/// Parses a base-10 integer, surrounding whitespace allowed. Returns false when
/// the text is not a number, so a non numeric query parameter is just skipped.
bool tryParseLong(const(char)[] s, out long value)
@safe nothrow pure {
    size_t b = 0, e = s.length;
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) b++;
    while (e > b && (s[e-1] == ' ' || s[e-1] == '\t' || s[e-1] == '\r' || s[e-1] == '\n')) e--;
    if (b >= e) return false;

    bool negative = false;
    if (s[b] == '+' || s[b] == '-') {
        negative = s[b] == '-';
        b++;
    }
    if (b >= e) return false;

    long acc = 0;
    foreach (c; s[b .. e]) {
        if (c < '0' || c > '9') return false;
        acc = acc * 10 + (c - '0');
    }
    value = negative ? -acc : acc;
    return true;
}

void handlePipeline(scope HTTPServerRequest req, scope HTTPServerResponse res)
@safe {
    res.writeBody("ok", "text/plain");
}

void handleBaseline11(scope HTTPServerRequest req, scope HTTPServerResponse res)
@safe {
    long total = 0;
    foreach (key, value; req.query.byKeyValue) {
        long n;
        if (tryParseLong(value, n)) total += n;
    }
    if (req.method == HTTPMethod.POST) {
        long n;
        if (tryParseLong(req.bodyReader.readAllUTF8(), n)) total += n;
    }
    res.writeBody(total.to!string, "text/plain");
}

void handleJson(scope HTTPServerRequest req, scope HTTPServerResponse res)
@safe {
    long count = 0;
    tryParseLong(req.params["count"], count);
    if (count < 0) count = 0;

    long m = 1;
    if (auto pm = "m" in req.query) {
        long v;
        if (tryParseLong(*pm, v)) m = v;
    }

    auto all = dataset;
    auto n = cast(size_t) min(count, cast(long) all.length);
    auto items = all[0 .. n].dup;
    foreach (ref item; items)
        item.total = item.price * item.quantity * m;

    res.writeJsonBody(ItemList(items, count));
}

/// POST /echo, the body handed back byte for byte. It is read through vibe.d's
/// own body reader, which has already undone chunked framing, so the response
/// is sized from what actually arrived rather than from a Content-Length the
/// request need not carry. writeBody sets that length and the content type.
void handleEcho(scope HTTPServerRequest req, scope HTTPServerResponse res)
@safe {
    auto payload = req.bodyReader.readAll();
    res.writeBody(payload, "application/octet-stream");
}

/// Server TLS context for the json-tls listener, or null when the harness did
/// not mount /certs. Returning null rather than throwing keeps the plaintext
/// profiles startable on their own: validate.sh only mounts the directory for
/// entries that subscribe to a TLS test.
TLSContext serverTLSContext()
@safe nothrow {
    import std.file : exists;

    enum certPath = "/certs/server.crt";
    enum keyPath = "/certs/server.key";

    try {
        if (!exists(certPath) || !exists(keyPath)) {
            logWarn("No certificate at %s, the TLS listener stays down", certPath);
            return null;
        }
        auto ctx = createTLSContext(TLSContextKind.server);
        ctx.useCertificateChainFile(certPath);
        ctx.usePrivateKeyFile(keyPath);
        // json-tls is HTTP/1.1 only. Without this the extension is absent and a
        // client falls back to 1.1 anyway, but saying so explicitly keeps an h2
        // capable client from ever being offered the upgrade.
        ctx.alpnCallback = (string[] offered) {
            foreach (proto; offered)
                if (proto == "http/1.1") return proto;
            return null;  // no overlap: let the client fall back
        };
        return ctx;
    } catch (Exception e) {
        logWarn("TLS setup failed (%s), the TLS listener stays down", e.msg);
        return null;
    }
}

/// Cores this container may actually use: the cgroup v2 quota first, then the
/// CPU affinity mask, and the machine size only if both are unavailable.
uint availableCores()
@trusted nothrow {
    import core.sys.linux.sched : CPU_COUNT, cpu_set_t, sched_getaffinity;
    import std.file : exists, readText;
    import std.string : split, strip;

    try {
        if (exists("/sys/fs/cgroup/cpu.max")) {
            auto parts = readText("/sys/fs/cgroup/cpu.max").strip().split(" ");
            if (parts.length == 2 && parts[0] != "max") {
                immutable quota = parts[0].to!long;
                immutable period = parts[1].to!long;
                if (period > 0 && quota / period >= 1)
                    return cast(uint) (quota / period);
            }
        }
    } catch (Exception e) {}

    cpu_set_t mask;
    if (sched_getaffinity(0, cpu_set_t.sizeof, &mask) == 0) {
        immutable n = CPU_COUNT(&mask);
        if (n >= 1) return cast(uint) n;
    }

    try {
        import std.parallelism : totalCPUs;
        return totalCPUs;
    } catch (Exception e) {}

    return 1;
}

void loadDataset()
@trusted {
    import std.file : readText;
    import std.process : environment;

    immutable path = environment.get("DATASET_PATH", "/data/dataset.json");
    try {
        g_dataset = deserializeJson!(Item[])(parseJsonString(readText(path)));
        logInfo("Loaded %s dataset items from %s", g_dataset.length, path);
    } catch (Exception e) {
        // No dataset is not fatal: /json then answers with an empty list.
        logWarn("Could not read %s (%s), serving an empty dataset", path, e.msg);
        g_dataset = null;
    }
}

int main(string[] args)
{
    loadDataset();

    // One listener task per core, each with its own accept queue on the shared
    // port (SO_REUSEPORT), which is how vibe.d scales past a single thread.
    setupWorkerThreads(availableCores());
    runWorkerTaskDist(() nothrow {
        try {
            auto router = new URLRouter;
            router.get("/pipeline", &handlePipeline);
            router.get("/baseline11", &handleBaseline11);
            router.post("/baseline11", &handleBaseline11);
            router.get("/json/:count", &handleJson);
            router.post("/echo", &handleEcho);
            router.rebuild();

            auto settings = new HTTPServerSettings;
            settings.port = 8080;
            settings.bindAddresses = ["0.0.0.0"];
            settings.options = HTTPServerOption.reusePort | HTTPServerOption.reuseAddress;
            // /echo takes a 100 KB body; the default cap is 2 MB, and this
            // leaves room for anything a later profile posts.
            settings.maxRequestSize = 64 * 1024 * 1024;
            // standard mode: gzip is vibe.d's own Accept-Encoding negotiation,
            // nothing hand-rolled and nothing compressed unasked.
            settings.useCompressionIfPossible = true;
            settings.serverString = "vibe.d";

            listenHTTP(settings, router);

            // json-tls: the same router behind TLS on 8081, one listener per
            // worker exactly like the plaintext one, so the profile is served
            // by every core instead of whichever thread happened to bind it.
            if (auto tlsCtx = serverTLSContext()) {
                auto tlsSettings = new HTTPServerSettings;
                tlsSettings.port = H1TLS_PORT;
                tlsSettings.bindAddresses = ["0.0.0.0"];
                tlsSettings.options = HTTPServerOption.reusePort | HTTPServerOption.reuseAddress;
                tlsSettings.maxRequestSize = 64 * 1024 * 1024;
                tlsSettings.useCompressionIfPossible = true;
                tlsSettings.serverString = "vibe.d";
                tlsSettings.tlsContext = tlsCtx;
                listenHTTP(tlsSettings, router);
            }
        } catch (Exception e) assert(false, e.msg);
    });

    return runApplication(&args);
}
