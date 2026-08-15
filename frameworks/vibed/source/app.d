module app;

import vibe.core.core : runApplication, runWorkerTaskDist, setupWorkerThreads;
import vibe.core.log : logInfo, logWarn;
import vibe.core.stream : nullSink, pipe;
import vibe.data.json : deserializeJson, parseJsonString;
import vibe.data.serialization : optional;
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.stream.operations : readAllUTF8;

import std.algorithm.comparison : min;
import std.conv : to;

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

void handleUpload(scope HTTPServerRequest req, scope HTTPServerResponse res)
@safe {
    auto received = req.bodyReader.pipe(nullSink);
    res.writeBody(received.to!string, "text/plain");
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
            router.post("/upload", &handleUpload);
            router.rebuild();

            auto settings = new HTTPServerSettings;
            settings.port = 8080;
            settings.bindAddresses = ["0.0.0.0"];
            settings.options = HTTPServerOption.reusePort | HTTPServerOption.reuseAddress;
            // The upload profile posts bodies of up to 20 MB; the default cap is 2 MB.
            settings.maxRequestSize = 64 * 1024 * 1024;
            // standard mode: gzip is vibe.d's own Accept-Encoding negotiation,
            // nothing hand-rolled and nothing compressed unasked.
            settings.useCompressionIfPossible = true;
            settings.serverString = "vibe.d";

            listenHTTP(settings, router);
        } catch (Exception e) assert(false, e.msg);
    });

    return runApplication(&args);
}
