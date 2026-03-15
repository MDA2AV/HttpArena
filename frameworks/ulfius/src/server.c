#include <ulfius.h>
#include <jansson.h>
#include <sqlite3.h>
#include <zlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <signal.h>

#define PORT 8080
#define TLS_PORT 8443
#define MAX_STATIC_FILES 64

/* ── Shared data ── */

static json_t *dataset_items = NULL;
static char *json_large_response = NULL;
static size_t json_large_len = 0;
static unsigned char *json_large_gzipped = NULL;
static size_t json_large_gzip_len = 0;

typedef struct {
    char name[256];
    char *data;
    size_t len;
    char content_type[64];
} StaticFile;

static StaticFile static_files[MAX_STATIC_FILES];
static int static_file_count = 0;

static int db_available = 0;

/* Thread-local DB */
static __thread sqlite3 *tl_db = NULL;
static __thread sqlite3_stmt *tl_stmt = NULL;

static sqlite3 *open_db(void) {
    sqlite3 *h = NULL;
    if (sqlite3_open_v2("/data/benchmark.db", &h,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (h) sqlite3_close(h);
        return NULL;
    }
    sqlite3_exec(h, "PRAGMA mmap_size=268435456", NULL, NULL, NULL);
    return h;
}

static sqlite3 *get_db(void) {
    if (!tl_db) {
        tl_db = open_db();
        if (tl_db) {
            const char *sql = "SELECT id, name, category, price, quantity, active, tags, "
                              "rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50";
            sqlite3_prepare_v2(tl_db, sql, -1, &tl_stmt, NULL);
        }
    }
    return tl_db;
}

/* ── Data loading ── */

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(len + 1);
    if (!buf) { fclose(f); return NULL; }
    fread(buf, 1, len, f);
    buf[len] = 0;
    fclose(f);
    if (out_len) *out_len = (size_t)len;
    return buf;
}

static void load_dataset(void) {
    const char *path = getenv("DATASET_PATH");
    if (!path) path = "/data/dataset.json";
    size_t len;
    char *data = read_file(path, &len);
    if (!data) return;
    json_error_t err;
    json_t *root = json_loads(data, 0, &err);
    free(data);
    if (!root || !json_is_array(root)) { json_decref(root); return; }

    /* Pre-compute total for each item */
    size_t i;
    json_t *item;
    json_array_foreach(root, i, item) {
        double price = json_number_value(json_object_get(item, "price"));
        json_int_t qty = json_integer_value(json_object_get(item, "quantity"));
        double total = round(price * qty * 100.0) / 100.0;
        json_object_set_new(item, "total", json_real(total));
    }
    dataset_items = root;
}

static unsigned char *gzip_compress(const char *input, size_t in_len, size_t *out_len) {
    uLongf bound = compressBound(in_len) + 32;
    unsigned char *buf = malloc(bound);
    if (!buf) return NULL;

    z_stream strm = {0};
    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        free(buf);
        return NULL;
    }
    strm.next_in = (Bytef *)input;
    strm.avail_in = in_len;
    strm.next_out = buf;
    strm.avail_out = bound;
    deflate(&strm, Z_FINISH);
    *out_len = strm.total_out;
    deflateEnd(&strm);
    return buf;
}

static void load_dataset_large(void) {
    size_t len;
    char *data = read_file("/data/dataset-large.json", &len);
    if (!data) return;
    json_error_t err;
    json_t *root = json_loads(data, 0, &err);
    free(data);
    if (!root || !json_is_array(root)) { json_decref(root); return; }

    size_t i;
    json_t *item;
    json_array_foreach(root, i, item) {
        double price = json_number_value(json_object_get(item, "price"));
        json_int_t qty = json_integer_value(json_object_get(item, "quantity"));
        double total = round(price * qty * 100.0) / 100.0;
        json_object_set_new(item, "total", json_real(total));
    }

    json_t *resp = json_object();
    json_object_set_new(resp, "items", root);
    json_object_set_new(resp, "count", json_integer(json_array_size(root)));
    json_large_response = json_dumps(resp, JSON_COMPACT);
    json_large_len = strlen(json_large_response);
    json_decref(resp);

    /* Pre-compress for /compression endpoint */
    json_large_gzipped = gzip_compress(json_large_response, json_large_len, &json_large_gzip_len);
}

static const char *mime_for_ext(const char *ext) {
    if (strcmp(ext, ".css") == 0) return "text/css";
    if (strcmp(ext, ".js") == 0) return "application/javascript";
    if (strcmp(ext, ".html") == 0) return "text/html";
    if (strcmp(ext, ".woff2") == 0) return "font/woff2";
    if (strcmp(ext, ".svg") == 0) return "image/svg+xml";
    if (strcmp(ext, ".webp") == 0) return "image/webp";
    if (strcmp(ext, ".json") == 0) return "application/json";
    return "application/octet-stream";
}

static void load_static_files(void) {
    DIR *d = opendir("/data/static");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && static_file_count < MAX_STATIC_FILES) {
        if (e->d_type != DT_REG) continue;
        char path[512];
        snprintf(path, sizeof(path), "/data/static/%s", e->d_name);
        size_t len;
        char *data = read_file(path, &len);
        if (!data) continue;
        StaticFile *sf = &static_files[static_file_count++];
        strncpy(sf->name, e->d_name, sizeof(sf->name) - 1);
        sf->data = data;
        sf->len = len;
        const char *dot = strrchr(e->d_name, '.');
        strncpy(sf->content_type, dot ? mime_for_ext(dot) : "application/octet-stream",
                sizeof(sf->content_type) - 1);
    }
    closedir(d);
}

/* ── Query param sum helper ── */

static long long sum_query_params(const struct _u_request *request) {
    long long sum = 0;
    const char *qs = u_map_get(request->map_url, NULL);
    /* Iterate all query parameters */
    int i;
    if (request->map_url) {
        for (i = 0; i < request->map_url->nb_values; i++) {
            char *endptr;
            long long val = strtoll(request->map_url->values[i], &endptr, 10);
            if (endptr != request->map_url->values[i]) {
                sum += val;
            }
        }
    }
    return sum;
}

/* ── Endpoint callbacks ── */

int cb_pipeline(const struct _u_request *request, struct _u_response *response, void *user_data) {
    ulfius_set_string_body_response(response, 200, "ok");
    u_map_put(response->map_header, "Content-Type", "text/plain");
    return U_CALLBACK_CONTINUE;
}

int cb_json(const struct _u_request *request, struct _u_response *response, void *user_data) {
    if (!dataset_items) {
        ulfius_set_string_body_response(response, 500, "No dataset");
        return U_CALLBACK_CONTINUE;
    }
    json_t *resp = json_object();
    json_object_set(resp, "items", dataset_items);
    json_object_set_new(resp, "count", json_integer(json_array_size(dataset_items)));
    char *body = json_dumps(resp, JSON_COMPACT);
    json_decref(resp);
    ulfius_set_string_body_response(response, 200, body);
    u_map_put(response->map_header, "Content-Type", "application/json");
    free(body);
    return U_CALLBACK_CONTINUE;
}

int cb_compression(const struct _u_request *request, struct _u_response *response, void *user_data) {
    if (!json_large_response) {
        ulfius_set_string_body_response(response, 500, "No dataset");
        return U_CALLBACK_CONTINUE;
    }
    /* Serve gzip if client accepts it and we have a pre-compressed version */
    const char *accept_enc = u_map_get(request->map_header, "Accept-Encoding");
    if (json_large_gzipped && accept_enc && strstr(accept_enc, "gzip")) {
        ulfius_set_binary_body_response(response, 200, (const char *)json_large_gzipped, json_large_gzip_len);
        u_map_put(response->map_header, "Content-Encoding", "gzip");
    } else {
        ulfius_set_binary_body_response(response, 200, json_large_response, json_large_len);
    }
    u_map_put(response->map_header, "Content-Type", "application/json");
    return U_CALLBACK_CONTINUE;
}

int cb_baseline2(const struct _u_request *request, struct _u_response *response, void *user_data) {
    long long sum = sum_query_params(request);
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", sum);
    ulfius_set_string_body_response(response, 200, buf);
    u_map_put(response->map_header, "Content-Type", "text/plain");
    return U_CALLBACK_CONTINUE;
}

int cb_upload(const struct _u_request *request, struct _u_response *response, void *user_data) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%zu", request->binary_body_length);
    ulfius_set_string_body_response(response, 200, buf);
    u_map_put(response->map_header, "Content-Type", "text/plain");
    return U_CALLBACK_CONTINUE;
}

int cb_baseline11(const struct _u_request *request, struct _u_response *response, void *user_data) {
    long long sum = sum_query_params(request);
    if (request->binary_body_length > 0 && request->binary_body) {
        char *body_str = malloc(request->binary_body_length + 1);
        if (body_str) {
            memcpy(body_str, request->binary_body, request->binary_body_length);
            body_str[request->binary_body_length] = 0;
            char *endptr;
            long long val = strtoll(body_str, &endptr, 10);
            if (endptr != body_str) sum += val;
            free(body_str);
        }
    }
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", sum);
    ulfius_set_string_body_response(response, 200, buf);
    u_map_put(response->map_header, "Content-Type", "text/plain");
    return U_CALLBACK_CONTINUE;
}

int cb_db(const struct _u_request *request, struct _u_response *response, void *user_data) {
    if (!db_available || !get_db() || !tl_stmt) {
        ulfius_set_string_body_response(response, 200, "{\"items\":[],\"count\":0}");
        u_map_put(response->map_header, "Content-Type", "application/json");
        return U_CALLBACK_CONTINUE;
    }
    double min_price = 10.0, max_price = 50.0;
    const char *v;
    if ((v = u_map_get(request->map_url, "min")) != NULL) min_price = atof(v);
    if ((v = u_map_get(request->map_url, "max")) != NULL) max_price = atof(v);

    json_t *items = json_array();
    sqlite3_reset(tl_stmt);
    sqlite3_bind_double(tl_stmt, 1, min_price);
    sqlite3_bind_double(tl_stmt, 2, max_price);
    while (sqlite3_step(tl_stmt) == SQLITE_ROW) {
        json_t *item = json_object();
        json_object_set_new(item, "id", json_integer(sqlite3_column_int64(tl_stmt, 0)));
        json_object_set_new(item, "name", json_string((const char *)sqlite3_column_text(tl_stmt, 1)));
        json_object_set_new(item, "category", json_string((const char *)sqlite3_column_text(tl_stmt, 2)));
        json_object_set_new(item, "price", json_real(sqlite3_column_double(tl_stmt, 3)));
        json_object_set_new(item, "quantity", json_integer(sqlite3_column_int64(tl_stmt, 4)));
        json_object_set_new(item, "active", sqlite3_column_int(tl_stmt, 5) ? json_true() : json_false());

        const char *tags_str = (const char *)sqlite3_column_text(tl_stmt, 6);
        json_error_t err;
        json_t *tags = json_loads(tags_str ? tags_str : "[]", 0, &err);
        json_object_set_new(item, "tags", tags ? tags : json_array());

        json_t *rating = json_object();
        json_object_set_new(rating, "score", json_real(sqlite3_column_double(tl_stmt, 7)));
        json_object_set_new(rating, "count", json_integer(sqlite3_column_int64(tl_stmt, 8)));
        json_object_set_new(item, "rating", rating);

        json_array_append_new(items, item);
    }

    json_t *resp_json = json_object();
    json_object_set_new(resp_json, "count", json_integer(json_array_size(items)));
    json_object_set_new(resp_json, "items", items);
    char *body = json_dumps(resp_json, JSON_COMPACT);
    json_decref(resp_json);

    ulfius_set_string_body_response(response, 200, body);
    u_map_put(response->map_header, "Content-Type", "application/json");
    free(body);
    return U_CALLBACK_CONTINUE;
}

int cb_static(const struct _u_request *request, struct _u_response *response, void *user_data) {
    const char *filename = u_map_get(request->map_url, "filename");
    if (!filename) {
        ulfius_set_string_body_response(response, 404, "Not found");
        return U_CALLBACK_CONTINUE;
    }
    for (int i = 0; i < static_file_count; i++) {
        if (strcmp(static_files[i].name, filename) == 0) {
            ulfius_set_binary_body_response(response, 200, static_files[i].data, static_files[i].len);
            u_map_put(response->map_header, "Content-Type", static_files[i].content_type);
            return U_CALLBACK_CONTINUE;
        }
    }
    ulfius_set_string_body_response(response, 404, "Not found");
    return U_CALLBACK_CONTINUE;
}

/* ── Main ── */

int main(void) {
    struct _u_instance instance;
    struct _u_instance instance_tls;

    load_dataset();
    load_dataset_large();
    load_static_files();

    {
        sqlite3 *test = open_db();
        if (test) { db_available = 1; sqlite3_close(test); }
    }

    if (ulfius_init_instance(&instance, PORT, NULL, NULL) != U_OK) {
        fprintf(stderr, "Error initializing ulfius on port %d\n", PORT);
        return 1;
    }
    instance.max_post_body_size = 25 * 1024 * 1024;

    ulfius_add_endpoint_by_val(&instance, "GET", "/pipeline", NULL, 0, &cb_pipeline, NULL);
    ulfius_add_endpoint_by_val(&instance, "GET", "/json", NULL, 0, &cb_json, NULL);
    ulfius_add_endpoint_by_val(&instance, "GET", "/compression", NULL, 0, &cb_compression, NULL);
    ulfius_add_endpoint_by_val(&instance, "GET", "/baseline2", NULL, 0, &cb_baseline2, NULL);
    ulfius_add_endpoint_by_val(&instance, "POST", "/upload", NULL, 0, &cb_upload, NULL);
    ulfius_add_endpoint_by_val(&instance, "GET", "/baseline11", NULL, 0, &cb_baseline11, NULL);
    ulfius_add_endpoint_by_val(&instance, "POST", "/baseline11", NULL, 0, &cb_baseline11, NULL);
    ulfius_add_endpoint_by_val(&instance, "GET", "/db", NULL, 0, &cb_db, NULL);
    ulfius_add_endpoint_by_val(&instance, "GET", "/static/:filename", NULL, 0, &cb_static, NULL);

    if (ulfius_start_framework(&instance) != U_OK) {
        fprintf(stderr, "Error starting ulfius framework\n");
        ulfius_clean_instance(&instance);
        return 1;
    }

    printf("Ulfius listening on port %d\n", PORT);

    /* TLS instance */
    const char *cert = getenv("TLS_CERT");
    const char *key = getenv("TLS_KEY");
    if (!cert) cert = "/certs/server.crt";
    if (!key) key = "/certs/server.key";

    int tls_started = 0;
    if (access(cert, R_OK) == 0 && access(key, R_OK) == 0) {
        char *cert_data = read_file(cert, NULL);
        char *key_data = read_file(key, NULL);
        if (cert_data && key_data) {
            if (ulfius_init_instance(&instance_tls, TLS_PORT, NULL, NULL) == U_OK) {
                instance_tls.max_post_body_size = 25 * 1024 * 1024;
                ulfius_add_endpoint_by_val(&instance_tls, "GET", "/pipeline", NULL, 0, &cb_pipeline, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "GET", "/json", NULL, 0, &cb_json, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "GET", "/compression", NULL, 0, &cb_compression, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "GET", "/baseline2", NULL, 0, &cb_baseline2, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "POST", "/upload", NULL, 0, &cb_upload, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "GET", "/baseline11", NULL, 0, &cb_baseline11, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "POST", "/baseline11", NULL, 0, &cb_baseline11, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "GET", "/db", NULL, 0, &cb_db, NULL);
                ulfius_add_endpoint_by_val(&instance_tls, "GET", "/static/:filename", NULL, 0, &cb_static, NULL);

                if (ulfius_start_secure_framework(&instance_tls, key_data, cert_data) == U_OK) {
                    printf("Ulfius TLS listening on port %d\n", TLS_PORT);
                    tls_started = 1;
                }
            }
        }
        free(cert_data);
        free(key_data);
    }

    /* Block forever */
    sigset_t set;
    int sig;
    sigemptyset(&set);
    sigaddset(&set, SIGTERM);
    sigaddset(&set, SIGINT);
    sigwait(&set, &sig);

    ulfius_stop_framework(&instance);
    ulfius_clean_instance(&instance);
    if (tls_started) {
        ulfius_stop_framework(&instance_tls);
        ulfius_clean_instance(&instance_tls);
    }

    if (dataset_items) json_decref(dataset_items);
    free(json_large_response);

    return 0;
}
