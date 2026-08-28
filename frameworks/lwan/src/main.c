/* HttpArena entry for lwan. */
#define _GNU_SOURCE
#include "lwan.h"
#include "lwan-array.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_ITEMS 512

struct rating {
    long score;
    long count;
};

struct item {
    long id;
    char *name;
    char *category;
    long price;
    long quantity;
    int active;
    char **tags;
    size_t n_tags;
    struct rating rating;
};

/* Read once before the workers start, then only read from handlers, so every
 * thread shares the one copy without locking. */
static struct item g_items[MAX_ITEMS];
static size_t g_n_items;

/* ---- a small JSON reader, used once at startup for /data/dataset.json ---- */

static const char *skip_ws(const char *p)
{
    while (*p && isspace((unsigned char)*p))
        p++;
    return p;
}

static const char *parse_string(const char *p, char **out)
{
    p = skip_ws(p);
    if (*p != '"')
        return NULL;
    p++;
    const char *start = p;
    while (*p && *p != '"')
        p += (*p == '\\' && p[1]) ? 2 : 1;
    if (*p != '"')
        return NULL;
    size_t len = (size_t)(p - start);
    *out = strndup(start, len);
    return p + 1;
}

static const char *read_long(const char *p, long *out)
{
    p = skip_ws(p);
    char *end = NULL;
    *out = strtol(p, &end, 10);
    return end == p ? NULL : end;
}

static const char *skip_key(const char *p)
{
    char *k = NULL;
    p = parse_string(p, &k);
    free(k);
    if (!p)
        return NULL;
    p = skip_ws(p);
    return (*p == ':') ? p + 1 : NULL;
}

static const char *parse_item(const char *p, struct item *it)
{
    p = skip_ws(p);
    if (*p != '{')
        return NULL;
    p++;
    while (1) {
        p = skip_ws(p);
        if (*p == '}')
            return p + 1;
        char *key = NULL;
        const char *after = parse_string(p, &key);
        if (!after) {
            free(key);
            return NULL;
        }
        p = skip_ws(after);
        if (*p != ':') {
            free(key);
            return NULL;
        }
        p++;
        p = skip_ws(p);

        if (!strcmp(key, "id")) p = read_long(p, &it->id);
        else if (!strcmp(key, "name")) p = parse_string(p, &it->name);
        else if (!strcmp(key, "category")) p = parse_string(p, &it->category);
        else if (!strcmp(key, "price")) p = read_long(p, &it->price);
        else if (!strcmp(key, "quantity")) p = read_long(p, &it->quantity);
        else if (!strcmp(key, "active")) {
            it->active = (*p == 't');
            p += (*p == 't') ? 4 : 5;
        } else if (!strcmp(key, "tags")) {
            if (*p != '[') { free(key); return NULL; }
            p++;
            it->n_tags = 0;
            it->tags = calloc(16, sizeof(char *));
            while (1) {
                p = skip_ws(p);
                if (*p == ']') { p++; break; }
                if (*p == ',') { p++; continue; }
                char *tag = NULL;
                p = parse_string(p, &tag);
                if (!p) { free(key); return NULL; }
                if (it->n_tags < 16)
                    it->tags[it->n_tags++] = tag;
                else
                    free(tag);
            }
        } else if (!strcmp(key, "rating")) {
            if (*p != '{') { free(key); return NULL; }
            p++;
            while (1) {
                p = skip_ws(p);
                if (*p == '}') { p++; break; }
                if (*p == ',') { p++; continue; }
                char *rk = NULL;
                const char *a2 = parse_string(p, &rk);
                if (!a2) { free(rk); free(key); return NULL; }
                p = skip_ws(a2);
                if (*p != ':') { free(rk); free(key); return NULL; }
                p++;
                long v = 0;
                p = read_long(p, &v);
                if (!p) { free(rk); free(key); return NULL; }
                if (!strcmp(rk, "score")) it->rating.score = v;
                else if (!strcmp(rk, "count")) it->rating.count = v;
                free(rk);
            }
        } else {
            /* unknown key: skip a scalar value */
            while (*p && *p != ',' && *p != '}')
                p++;
        }
        free(key);
        if (!p)
            return NULL;
        p = skip_ws(p);
        if (*p == ',')
            p++;
    }
}

static void load_dataset(void)
{
    const char *path = getenv("DATASET_PATH");
    if (!path)
        path = "/data/dataset.json";

    FILE *f = fopen(path, "rb");
    if (!f)
        return; /* no dataset is not fatal: /json answers with an empty list */
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)size + 1);
    if (!buf || fread(buf, 1, (size_t)size, f) != (size_t)size) {
        free(buf);
        fclose(f);
        return;
    }
    buf[size] = '\0';
    fclose(f);

    const char *p = skip_ws(buf);
    if (*p == '[') {
        p++;
        while (g_n_items < MAX_ITEMS) {
            p = skip_ws(p);
            if (*p == ']' || !*p)
                break;
            if (*p == ',') { p++; continue; }
            const char *next = parse_item(p, &g_items[g_n_items]);
            if (!next)
                break;
            g_n_items++;
            p = next;
        }
    }
    free(buf);
}

/* ------------------------------- handlers ------------------------------- */

static int parse_int_strict(const char *s, long *out)
{
    if (!s || !*s)
        return 0;
    while (*s && isspace((unsigned char)*s))
        s++;
    int neg = 0;
    if (*s == '+' || *s == '-') {
        neg = (*s == '-');
        s++;
    }
    if (!*s)
        return 0;
    long acc = 0;
    for (; *s; s++) {
        if (isspace((unsigned char)*s))
            break;
        if (*s < '0' || *s > '9')
            return 0;
        acc = acc * 10 + (*s - '0');
    }
    *out = neg ? -acc : acc;
    return 1;
}

LWAN_HANDLER_ROUTE(baseline11, "/baseline11")
{
    long total = 0;

    const struct lwan_key_value_array *qs = lwan_request_get_query_params(request);
    if (qs) {
        struct lwan_key_value *kv;
        LWAN_ARRAY_FOREACH (qs, kv) {
            long n;
            if (kv->key && kv->value && parse_int_strict(kv->value, &n))
                total += n;
        }
    }

    const struct lwan_value *body = lwan_request_get_request_body(request);
    if (body && body->value && body->len) {
        char tmp[64];
        size_t n = body->len < sizeof(tmp) - 1 ? body->len : sizeof(tmp) - 1;
        memcpy(tmp, body->value, n);
        tmp[n] = '\0';
        long v;
        if (parse_int_strict(tmp, &v))
            total += v;
    }

    response->mime_type = "text/plain";
    lwan_strbuf_printf(response->buffer, "%ld", total);
    return HTTP_OK;
}

/* Routed on the "/json/" prefix; lwan leaves the remainder in request->url. */
LWAN_HANDLER_ROUTE(json_items, "/json/")
{
    long count = 0;
    if (request->url.value && request->url.len) {
        char tmp[32];
        size_t n = request->url.len < sizeof(tmp) - 1 ? request->url.len : sizeof(tmp) - 1;
        memcpy(tmp, request->url.value, n);
        tmp[n] = '\0';
        if (!parse_int_strict(tmp, &count))
            count = 0;
    }
    if (count < 0)
        count = 0;

    long m = 1;
    const char *m_raw = lwan_request_get_query_param(request, "m");
    if (m_raw) {
        long v;
        if (parse_int_strict(m_raw, &v))
            m = v;
    }

    size_t limit = (size_t)count < g_n_items ? (size_t)count : g_n_items;

    lwan_strbuf_append_strz(response->buffer, "{\"items\":[");
    for (size_t i = 0; i < limit; i++) {
        const struct item *it = &g_items[i];
        if (i)
            lwan_strbuf_append_char(response->buffer, ',');
        lwan_strbuf_append_printf(
            response->buffer,
            "{\"id\":%ld,\"name\":\"%s\",\"category\":\"%s\",\"price\":%ld,"
            "\"quantity\":%ld,\"active\":%s,\"tags\":[",
            it->id, it->name ? it->name : "", it->category ? it->category : "",
            it->price, it->quantity, it->active ? "true" : "false");
        for (size_t t = 0; t < it->n_tags; t++) {
            if (t)
                lwan_strbuf_append_char(response->buffer, ',');
            lwan_strbuf_append_printf(response->buffer, "\"%s\"", it->tags[t]);
        }
        lwan_strbuf_append_printf(
            response->buffer,
            "],\"rating\":{\"score\":%ld,\"count\":%ld},\"total\":%ld}",
            it->rating.score, it->rating.count, it->price * it->quantity * m);
    }
    lwan_strbuf_append_printf(response->buffer, "],\"count\":%zu}", limit);

    response->mime_type = "application/json";
    return HTTP_OK;
}

LWAN_HANDLER_ROUTE(upload, "/upload")
{
    const struct lwan_value *body = lwan_request_get_request_body(request);
    response->mime_type = "text/plain";
    lwan_strbuf_printf(response->buffer, "%zu", body ? body->len : (size_t)0);
    return HTTP_OK;
}

int main(void)
{
    load_dataset();
    return lwan_main();
}
