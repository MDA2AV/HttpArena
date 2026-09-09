/*
 * HttpArena entry for libioxd: the HTTP/1.1 profiles an engine is scored on, plus static-tls.
 *
 *   GET/POST /baseline11?a=&b=      text/plain: the sum of the query values, plus the body on POST
 *   GET      /delay/{ms}            text/plain "{ms}", after that many milliseconds on the ring
 *   GET      /json/{count}?m={m}    application/json: the first count dataset items, total = price x quantity x m
 *   POST     /echo                  the request body back as it came, Content-Length or chunked
 *   GET      /static/{file}         the file from /data/static; its .br or .gz twin when Accept-Encoding takes it
 *
 * Plain HTTP/1.1 on :8080; TLS 1.3 on :8081 with the pair the harness mounts (/certs/server.crt
 * and server.key, or TLS_CERT and TLS_KEY). The dataset (/data/dataset.json, or DATASET_PATH) is
 * parsed once at startup. Static files are opened, sized and read on every request: nothing is
 * cached, so a file replaced on disk is served at once.
 *
 * Every handler is linear code on a stackful coroutine: a body read, a delay or a send that has
 * to wait parks the connection on the ring, and the worker serves its other connections meanwhile.
 */
#include <ioxd.h>

#include <cjson/cJSON.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#define PIECE 8192                              /* the reply slab: what one ioxd_reserve may claim */

/* ── helpers ───────────────────────────────────────────────────────────────────────────── */

/* An integer written straight into the reply slab: no snprintf, no copy. */
static void put_i64(ioxd_ctx *ctx, int64_t v)
{
    char     tmp[21];
    int      t = 0;
    uint64_t u = v < 0 ? -(uint64_t)v : (uint64_t)v;
    do {
        tmp[t++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    if (v < 0)
        tmp[t++] = '-';
    char *out = ioxd_reserve(ctx, (size_t)t);
    if (!out)
        return;
    for (int i = 0; i < t; i++)
        out[i] = tmp[t - 1 - i];
    ioxd_advance(ctx, (size_t)t);
}

/* A query parameter's value, if the request has it. */
static bool param(const ioxd_ctx *ctx, const char *key, ioxd_slice *out)
{
    for (size_t i = 0; i < ctx->req.n_params; i++)
        if (ioxd_slice_eq(ctx->req.params[i].key, key)) {
            *out = ctx->req.params[i].value;
            return true;
        }
    return false;
}

/* A request header's value, or an empty slice. Names arrive lower-cased. */
static ioxd_slice header(const ioxd_ctx *ctx, const char *name)
{
    for (size_t i = 0; i < ctx->req.n_headers; i++)
        if (ioxd_slice_eq(ctx->req.headers[i].key, name))
            return ctx->req.headers[i].value;
    return (ioxd_slice){ 0 };
}

/* ── baseline, async ───────────────────────────────────────────────────────────────────── */

/* GET/POST /baseline11?a=&b= - the sum of the query values, and of the body's on POST. The
 * query arrives split into key/value slices; the body is read on demand, Content-Length or
 * chunked, decoded. */
static void baseline11(ioxd_ctx *ctx)
{
    int64_t sum = 0, v;
    for (size_t i = 0; i < ctx->req.n_params; i++)
        if (ioxd_to_i64(ctx->req.params[i].value, &v))
            sum += v;
    if ((ctx->req.content_length || ctx->req.chunked) && ioxd_to_i64(ioxd_slice_trim(ioxd_body_all(ctx)), &v))
        sum += v;
    put_i64(ctx, sum);
}

/* GET /delay/:ms - the number back, after that many milliseconds. ioxd_delay is the kernel's
 * timer on the ring: the coroutine parks, nothing blocks, and the worker serves its other
 * connections meanwhile. Zero waits for nothing. */
static void delay(ioxd_ctx *ctx)
{
    int64_t ms;
    if (!ioxd_to_i64(ctx->req.route_params[0].value, &ms) || ms < 0 || ms > UINT_MAX) {
        ctx->res.status = 400;
        return;
    }
    if (ms > 0 && ioxd_delay((unsigned)ms) != 0) {
        ctx->res.status = 503;                       /* the server is stopping */
        return;
    }
    put_i64(ctx, ms);
}

/* ── json ──────────────────────────────────────────────────────────────────────────────── */

/* An item as the reply writes it: the dataset's fields in the dataset's order, then the total
 * this request computes. Described once; item_to_json comes out of the description. */
#define RATING_FIELDS(X)                        \
    X(VALUE,  int64_t,      score)              \
    X(VALUE,  int64_t,      count)
IOXD_JSON_STRUCT(rating, RATING_FIELDS)

#define ITEM_FIELDS(X)                          \
    X(VALUE,  int64_t,      id)                 \
    X(VALUE,  const char *, name)               \
    X(VALUE,  const char *, category)           \
    X(VALUE,  int64_t,      price)              \
    X(VALUE,  int64_t,      quantity)           \
    X(VALUE,  bool,         active)             \
    X(ARRAY,  const char *, tags, n_tags)       \
    X(OBJECT, rating,       rating)             \
    X(VALUE,  int64_t,      total)
IOXD_JSON_STRUCT(item, ITEM_FIELDS)

static struct item *g_items;
static size_t       g_n_items;

static int64_t number_of(const cJSON *object, const char *key)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsNumber(v) ? (int64_t)v->valuedouble : 0;
}

static const char *string_of(const cJSON *object, const char *key)
{
    const char *s = cJSON_GetStringValue(cJSON_GetObjectItemCaseSensitive(object, key));
    return s ? s : "";
}

/* The dataset, parsed once at startup. The strings stay in the cJSON tree, which is kept for the
 * life of the process. */
static bool load_dataset(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "dataset %s: %s - /json will answer 503\n", path, strerror(errno));
        return false;
    }
    char  *text = NULL;
    size_t len = 0, cap = 0;
    for (;;) {
        if (len == cap) {
            cap  = cap ? cap * 2 : 65536;
            text = realloc(text, cap + 1);
            if (!text)
                abort();
        }
        size_t n = fread(text + len, 1, cap - len, f);
        if (n == 0)
            break;
        len += n;
    }
    fclose(f);
    text[len] = '\0';
    cJSON *root = cJSON_ParseWithLength(text, len);
    free(text);
    if (!cJSON_IsArray(root)) {
        fprintf(stderr, "dataset %s: not a JSON array - /json will answer 503\n", path);
        return false;
    }
    size_t       n     = (size_t)cJSON_GetArraySize(root);
    struct item *items = calloc(n ? n : 1, sizeof *items);
    if (!items)
        abort();
    size_t       i = 0;
    const cJSON *e;
    cJSON_ArrayForEach(e, root) {
        const cJSON *tags   = cJSON_GetObjectItemCaseSensitive(e, "tags");
        const cJSON *rating = cJSON_GetObjectItemCaseSensitive(e, "rating");
        if (!cJSON_IsObject(e) || !cJSON_IsArray(tags) || !cJSON_IsObject(rating)) {
            fprintf(stderr, "dataset %s: item %zu is not shaped like the arena's - /json will answer 503\n", path, i);
            return false;
        }
        struct item *it = &items[i++];
        it->id       = number_of(e, "id");
        it->name     = string_of(e, "name");
        it->category = string_of(e, "category");
        it->price    = number_of(e, "price");
        it->quantity = number_of(e, "quantity");
        it->active   = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(e, "active"));
        size_t       k = (size_t)cJSON_GetArraySize(tags);
        const char **t = calloc(k ? k : 1, sizeof *t);
        if (!t)
            abort();
        size_t       j = 0;
        const cJSON *tag;
        cJSON_ArrayForEach(tag, tags) {
            const char *s = cJSON_GetStringValue(tag);
            t[j++] = s ? s : "";
        }
        it->tags         = t;
        it->n_tags       = k;
        it->rating.score = number_of(rating, "score");
        it->rating.count = number_of(rating, "count");
    }
    g_items   = items;
    g_n_items = n;
    return true;
}

/* GET /json/:count?m= - {"items":[...],"count":n}: the first count items, each with
 * total = price x quantity x m computed for this request, serialized straight into the reply
 * slab and streamed as it fills. */
static void json(ioxd_ctx *ctx)
{
    int64_t    count, m = 1;
    ioxd_slice s;
    if (!ioxd_to_i64(ctx->req.route_params[0].value, &count) || count < 0 || (param(ctx, "m", &s) && !ioxd_to_i64(s, &m))) {
        ctx->res.status = 400;
        return;
    }
    if (!g_items) {
        ctx->res.status = 503;
        return;
    }
    if ((uint64_t)count > g_n_items)
        count = (int64_t)g_n_items;

    ioxd_json j = ioxd_json_reply(ctx);              /* content-type: application/json */
    ioxd_json_object(&j);
    ioxd_json_key(&j, "items");
    ioxd_json_array(&j);
    for (int64_t i = 0; i < count; i++) {
        struct item it = g_items[i];
        it.total = it.price * it.quantity * m;
        if (!item_to_json(&j, &it))
            return;                                  /* the peer is gone */
    }
    ioxd_json_end(&j);
    IOXD_JSON_FIELD(&j, "count", count);
    ioxd_json_end(&j);
}

/* ── 8gbit ─────────────────────────────────────────────────────────────────────────────── */

/* POST /echo - the body back as it came. Each piece is read from the request's framing
 * (Content-Length or chunked, decoded) straight into the reply slab and goes out as the next is
 * read: no buffer of its own, no copy. A request with a Content-Length gets a reply framed the
 * same way; a chunked one streams chunked. */
static void echo(ioxd_ctx *ctx)
{
    ctx->res.content_type = (ioxd_slice){ "application/octet-stream", 24 };
    if (!ctx->req.chunked)
        ioxd_content_length(ctx, ctx->req.content_length);
    for (;;) {
        char *at = ioxd_reserve(ctx, PIECE);
        if (!at)
            return;                                  /* the peer is gone */
        int n = ioxd_body_read_until(ctx, at, PIECE);
        if (n <= 0)
            return;                                  /* the end, or a body the engine refused */
        ioxd_advance(ctx, (size_t)n);
    }
}

/* ── static-tls ────────────────────────────────────────────────────────────────────────── */

static const char *g_static = "/data/static";

/* The content type from the extension, and whether a .br/.gz twin is worth looking for. */
static const struct { const char *ext, *type; bool twins; } types[] = {
    { ".css",   "text/css",               true  },
    { ".js",    "application/javascript", true  },
    { ".html",  "text/html",              true  },
    { ".json",  "application/json",       true  },
    { ".svg",   "image/svg+xml",          true  },
    { ".woff2", "font/woff2",             false },
    { ".webp",  "image/webp",             false },
};

/* Does Accept-Encoding take this coding? A list of coding[;q=...], "*" standing for any of
 * them; q=0 refuses one. */
static bool accepts(ioxd_slice ae, const char *coding)
{
    size_t      clen = strlen(coding);
    const char *p = ae.p, *end = ae.p + ae.len;
    while (p < end) {
        const char *tok = p;
        while (p < end && *p != ',')
            p++;
        const char *tend = p;
        if (p < end)
            p++;
        while (tok < tend && (*tok == ' ' || *tok == '\t'))
            tok++;
        const char *name_end = tok;
        while (name_end < tend && *name_end != ';' && *name_end != ' ' && *name_end != '\t')
            name_end++;
        size_t nlen = (size_t)(name_end - tok);
        if (!((nlen == clen && strncasecmp(tok, coding, clen) == 0) || (nlen == 1 && *tok == '*')))
            continue;
        bool refused = false;
        for (const char *q = name_end; q + 1 < tend; q++)
            if ((*q == 'q' || *q == 'Q') && q[1] == '=') {
                const char *v = q + 2;
                refused = true;
                while (v < tend && (*v == '0' || *v == '.'))
                    v++;
                if (v < tend && *v >= '1' && *v <= '9')
                    refused = false;
                break;
            }
        return !refused;
    }
    return false;
}

/* GET /static/:name - the file, or a 404. A compressible file whose .br or .gz twin sits beside
 * it on disk goes out as that twin when the client takes the coding, with the base file's type
 * and the matching Content-Encoding. Opened, sized and read on every request: nothing is
 * cached, so a file replaced on disk is served at once. One path segment names the file, so it
 * cannot leave the directory; a hidden name is refused all the same. */
static void static_file(ioxd_ctx *ctx)
{
    char name[NAME_MAX + 1];
    if (!ioxd_cstr(ctx->req.route_params[0].value, name, sizeof name) || name[0] == '\0' || name[0] == '.' || strchr(name, '/')) {
        ctx->res.status = 404;
        return;
    }
    const char *type  = "application/octet-stream";
    bool        twins = false;
    const char *dot   = strrchr(name, '.');
    if (dot)
        for (size_t i = 0; i < sizeof types / sizeof *types; i++)
            if (strcmp(dot, types[i].ext) == 0) {
                type  = types[i].type;
                twins = types[i].twins;
                break;
            }

    char        path[PATH_MAX];
    int         fd       = -1;
    const char *encoding = NULL;
    if (twins) {
        ioxd_slice ae = header(ctx, "accept-encoding");
        if (accepts(ae, "br")) {
            snprintf(path, sizeof path, "%s/%s.br", g_static, name);
            if ((fd = open(path, O_RDONLY | O_CLOEXEC)) >= 0)
                encoding = "br";
        }
        if (fd < 0 && accepts(ae, "gzip")) {
            snprintf(path, sizeof path, "%s/%s.gz", g_static, name);
            if ((fd = open(path, O_RDONLY | O_CLOEXEC)) >= 0)
                encoding = "gzip";
        }
    }
    if (fd < 0) {
        snprintf(path, sizeof path, "%s/%s", g_static, name);
        fd = open(path, O_RDONLY | O_CLOEXEC);
    }
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        if (fd >= 0)
            close(fd);
        ctx->res.status = 404;
        return;
    }

    ctx->res.content_type = (ioxd_slice){ type, strlen(type) };
    if (encoding)
        ioxd_header(ctx, "content-encoding", encoding);
    if (twins)
        ioxd_header(ctx, "vary", "accept-encoding");
    ioxd_content_length(ctx, (size_t)st.st_size);   /* Content-Length framing, whatever the size */
    for (off_t left = st.st_size; left > 0;) {
        size_t piece = left < PIECE ? (size_t)left : PIECE;
        char  *at    = ioxd_reserve(ctx, piece);     /* room in the slab, flushed first when full */
        if (!at)
            break;                                   /* the peer is gone */
        ssize_t n = read(fd, at, piece);
        if (n <= 0)
            break;                                   /* short of the declared length: the engine closes */
        ioxd_advance(ctx, (size_t)n);
        left -= n;
    }
    close(fd);
}

/* ── TLS ───────────────────────────────────────────────────────────────────────────────── */

/* libioxd loads a store laid out as <dir>/<host>/cert.pem + key.pem; the harness mounts one pair
 * as /certs/server.crt + server.key (TLS_CERT and TLS_KEY name another). A `default` host of
 * links to the pair is that store - and follows the mounted files, as links do. */
#define CERTS_DIR "/tmp/libioxd-certs"

static bool link_to(const char *target, const char *link)
{
    unlink(link);
    if (symlink(target, link) == 0)
        return true;
    fprintf(stderr, "%s: %s: :8081 (TLS) is not served\n", link, strerror(errno));
    return false;
}

static ioxd_certs *arena_certs(void)
{
    const char *crt = getenv("TLS_CERT"), *key = getenv("TLS_KEY");
    if (!crt || !*crt)
        crt = "/certs/server.crt";
    if (!key || !*key)
        key = "/certs/server.key";
    char crt_abs[PATH_MAX], key_abs[PATH_MAX];
    if (!realpath(crt, crt_abs) || !realpath(key, key_abs)) {
        fprintf(stderr, "no certificate pair at %s + %s (%s): :8081 (TLS) is not served\n", crt, key, strerror(errno));
        return NULL;
    }
    if ((mkdir(CERTS_DIR, 0755) != 0 && errno != EEXIST) || (mkdir(CERTS_DIR "/default", 0755) != 0 && errno != EEXIST)) {
        fprintf(stderr, CERTS_DIR "/default: %s: :8081 (TLS) is not served\n", strerror(errno));
        return NULL;
    }
    if (!link_to(crt_abs, CERTS_DIR "/default/cert.pem") || !link_to(key_abs, CERTS_DIR "/default/key.pem"))
        return NULL;
    return ioxd_certs_load(CERTS_DIR);               /* NULL, with the reason on stderr */
}

int main(int argc, char **argv)
{
    int         workers = argc > 1 ? atoi(argv[1]) : 0;   /* 0: one worker per CPU in the affinity mask */
    const char *dataset = getenv("DATASET_PATH");
    const char *root    = getenv("STATIC_ROOT");
    if (root && *root)
        g_static = root;
    load_dataset(dataset && *dataset ? dataset : "/data/dataset.json");

    IOXD_GET ("/baseline11",   baseline11);
    IOXD_POST("/baseline11",   baseline11);
    IOXD_GET ("/delay/:ms",    delay);
    IOXD_GET ("/json/:count",  json);
    IOXD_POST("/echo",         echo);
    IOXD_GET ("/static/:name", static_file);

    if (ioxd_bind(8080, NULL) != 0)
        return 1;
    ioxd_certs *certs = arena_certs();
    if (certs && ioxd_bind(8081, certs) != 0)
        return 1;
    return ioxd_run(workers);
}
