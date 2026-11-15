#include "dataset.h"
#include <cjson/cJSON.h>

static dataset_item_t *g_items = NULL;
static size_t          g_num_items = 0;

static int64_t cjson_int(const cJSON *obj, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(obj, key);
    return cJSON_IsNumber(v) ? (int64_t)v->valuedouble : 0;
}

static const char* cjson_str(const cJSON *obj, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(obj, key);
    return cJSON_IsString(v) ? v->valuestring : "";
}

bool dataset_load(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return false; }

    char *buf = malloc(sz + 1);
    if (!buf) { fclose(f); return false; }
    size_t rd = fread(buf, 1, sz, f);
    fclose(f);
    buf[rd] = '\0';

    cJSON *root = cJSON_ParseWithLength(buf, rd);
    free(buf);
    if (!cJSON_IsArray(root)) return false;

    g_num_items = (size_t)cJSON_GetArraySize(root);
    g_items = calloc(g_num_items, sizeof(dataset_item_t));
    if (!g_items) return false;

    size_t idx = 0;
    const cJSON *item_node = NULL;
    cJSON_ArrayForEach(item_node, root) {
        dataset_item_t *it = &g_items[idx++];
        it->id = cjson_int(item_node, "id");
        it->price = cjson_int(item_node, "price");
        it->quantity = cjson_int(item_node, "quantity");
        it->base_total = it->price * it->quantity;
        it->name = strdup(cjson_str(item_node, "name"));
        it->category = strdup(cjson_str(item_node, "category"));

        const cJSON *act = cJSON_GetObjectItemCaseSensitive(item_node, "active");
        it->active = cJSON_IsTrue(act);

        const cJSON *rt = cJSON_GetObjectItemCaseSensitive(item_node, "rating");
        if (rt) {
            it->score = cjson_int(rt, "score");
            it->count = cjson_int(rt, "count");
        }

        const cJSON *tags = cJSON_GetObjectItemCaseSensitive(item_node, "tags");
        if (cJSON_IsArray(tags)) {
            it->num_tags = (size_t)cJSON_GetArraySize(tags);
            it->tags = calloc(it->num_tags, sizeof(char*));
            size_t tidx = 0;
            const cJSON *tag_node = NULL;
            cJSON_ArrayForEach(tag_node, tags) {
                it->tags[tidx++] = strdup(cJSON_GetStringValue(tag_node));
            }
        }

        char pbuf[2048];
        char *p = pbuf;
        p += sprintf(p, "{\"id\":%lld,\"name\":\"%s\",\"category\":\"%s\",\"price\":%lld,\"quantity\":%lld,\"active\":%s,\"tags\":[",
                     (long long)it->id, it->name, it->category, (long long)it->price, (long long)it->quantity,
                     it->active ? "true" : "false");

        for (size_t t = 0; t < it->num_tags; t++) {
            if (t > 0) *p++ = ',';
            p += sprintf(p, "\"%s\"", it->tags[t]);
        }

        p += sprintf(p, "],\"rating\":{\"score\":%lld,\"count\":%lld},\"total\":",
                     (long long)it->score, (long long)it->count);

        it->prefix_len = (size_t)(p - pbuf);
        it->prefix = malloc(it->prefix_len);
        memcpy(it->prefix, pbuf, it->prefix_len);
    }

    cJSON_Delete(root);
    return true;
}

size_t dataset_count(void) {
    return g_num_items;
}

size_t json_serialize(size_t count, int64_t multiplier, char *out_buf, size_t max_out) {
    (void)max_out;
    if (count > g_num_items) count = g_num_items;
    char *p = out_buf;

    memcpy(p, "{\"items\":[", 10); p += 10;

    for (size_t i = 0; i < count; i++) {
        if (i > 0) *p++ = ',';
        memcpy(p, g_items[i].prefix, g_items[i].prefix_len);
        p += g_items[i].prefix_len;
        int64_t total = (multiplier == 1) ? g_items[i].base_total : (g_items[i].base_total * multiplier);
        p += format_i64(p, total);
        *p++ = '}';
    }

    memcpy(p, "],\"count\":", 10); p += 10;
    p += format_i64(p, (int64_t)count);
    *p++ = '}';

    return (size_t)(p - out_buf);
}

void compress_worker_init(worker_compress_t *wc) {
    memset(wc, 0, sizeof(*wc));
    wc->zlib_stream.zalloc = Z_NULL;
    wc->zlib_stream.zfree = Z_NULL;
    wc->zlib_stream.opaque = Z_NULL;
    if (deflateInit2(&wc->zlib_stream, 1, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK) {
        wc->zlib_initialized = true;
    }
}

void compress_worker_destroy(worker_compress_t *wc) {
    if (wc->zlib_initialized) {
        deflateEnd(&wc->zlib_stream);
        wc->zlib_initialized = false;
    }
}

int compress_brotli(const char *in_buf, size_t in_len, char *out_buf, size_t max_out, size_t *out_len) {
    size_t encoded_size = max_out;
    BROTLI_BOOL res = BrotliEncoderCompress(
        1,
        BROTLI_DEFAULT_WINDOW,
        BROTLI_MODE_TEXT,
        in_len,
        (const uint8_t*)in_buf,
        &encoded_size,
        (uint8_t*)out_buf
    );

    if (!res) return -1;
    *out_len = encoded_size;
    return 0;
}

int compress_gzip(worker_compress_t *wc, const char *in_buf, size_t in_len, char *out_buf, size_t max_out, size_t *out_len) {
    if (!wc->zlib_initialized) return -1;

    z_stream *strm = &wc->zlib_stream;
    deflateReset(strm);
    strm->next_in = (Bytef*)in_buf;
    strm->avail_in = (uInt)in_len;
    strm->next_out = (Bytef*)out_buf;
    strm->avail_out = (uInt)max_out;

    int ret = deflate(strm, Z_FINISH);
    if (ret != Z_STREAM_END) return -1;

    *out_len = max_out - strm->avail_out;
    return 0;
}
