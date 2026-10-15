/*
 * HttpArena entry for libioxd: the HTTP/1.1 profiles an engine is scored on, plus static-tls.
 *
 *   GET/POST /baseline11?a=&b=      text/plain: the sum of the query values, plus the body on POST
 *   GET      /delay/{ms}            text/plain "{ms}", after that many milliseconds on the ring
 *   GET      /json/{count}?m={m}    application/json: the first count dataset items, total = price x quantity x m;
 *                                   brotli or gzip when Accept-Encoding takes it (json-comp)
 *   POST     /echo                  the request body back as it came, Content-Length or chunked
 *   GET      /static/{file}         the file from /data/static; its .br or .gz twin when Accept-Encoding takes it
 *
 * Plain HTTP/1.1 on :8080; TLS 1.3 on :8081 with the pair the harness mounts (/certs/server.crt
 * and server.key, or TLS_CERT and TLS_KEY). The dataset (/data/dataset.json, or DATASET_PATH) is
 * parsed once at startup. Static files are served by the library's static module: what a worker
 * served it keeps in memory and checks against the disk (inode, size, modification time) on
 * every request, so a file replaced on disk is served new at once.
 *
 * Every handler is linear code on a stackful coroutine: a body read, a delay or a send that has
 * to wait parks the connection on the ring, and the worker serves its other connections meanwhile.
 */
#include <ioxd.h>

#include <cjson/cJSON.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PIECE 16384                             /* the reply slab: what one ioxd_reserve may claim */

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
 * slab and streamed as it fills. The compression middleware on the route codes the reply with
 * brotli or gzip when the request's Accept-Encoding takes one - at the first flush, from the
 * slab, one call and one message for a body that fit it - and leaves a request without the
 * header alone. */
static void json(ioxd_ctx *ctx)
{
    int64_t    count, m = 1;
    ioxd_slice mult = ioxd_req_param(ctx, "m");
    if (!ioxd_to_i64(ctx->req.route_params[0].value, &count) || count < 0 || (mult.p && !ioxd_to_i64(mult, &m))) {
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

static ioxd_static *g_files;

/* GET /static/:name - the file, its .br or .gz twin when Accept-Encoding takes the coding, with
 * the base type and the matching Content-Encoding; 404 when there is no such file. The library
 * keeps what it served in memory and checks the file on disk before serving it again, so a
 * replaced file is served new at once. A body larger than the reply slab goes out from where
 * it is, in one message behind the head. */
static void static_file(ioxd_ctx *ctx)
{
    ioxd_static_serve(ctx, g_files);
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
    load_dataset(dataset && *dataset ? dataset : "/data/dataset.json");
    ioxd_configure(&(ioxd_config){ .recv_buffers = 512 });   /* 8 MB of receive buffers a worker instead of 16: a body of 10 KB still arrives in one delivery, and 512 still covers a worker's share of the 16384-connection profiles (256) without parking a recv on -ENOBUFS */
    ioxd_compress_configure(&(ioxd_compress_config){ .brotli_quality = 0 });   /* the one-pass brotli: 4% more replies a second than quality 1, bodies 4% larger */
    g_files = ioxd_static_open(&(ioxd_static_config){
        .dir           = root && *root ? root : "/data/static",
        .mount         = "/static",
        .precompressed = true,                       /* the .br and .gz twins on disk, by Accept-Encoding */
    });
    if (!g_files)
        return 1;                                    /* the reason is on stderr */

    IOXD_GET ("/baseline11",   baseline11);
    IOXD_POST("/baseline11",   baseline11);
    IOXD_GET ("/delay/:ms",    delay);
    IOXD_GET ("/json/:count",  json, ioxd_compress);   /* coded when the client takes br or gzip: json-comp */
    IOXD_POST("/echo",         echo);
    IOXD_GET ("/static/:name", static_file);

    if (ioxd_bind(8080, NULL) != 0)
        return 1;
    ioxd_certs *certs = arena_certs();
    if (certs && ioxd_bind(8081, certs) != 0)
        return 1;
    return ioxd_run(workers);
}
