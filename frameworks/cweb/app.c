#define _GNU_SOURCE
#include <sched.h>
#include <cweb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <zlib.h>
#include <brotli/encode.h>

typedef struct {
    long long id;
    char name[64];
    char category[32];
    long long price;
    long long quantity;
    bool active;
    char tags_raw[128]; // Pre-formatted JSON array e.g. ["tag1","tag2"]
    long long rating_score;
    long long rating_count;
} DatasetItem;

static DatasetItem g_items[64];
static int g_num_items = 0;

// Parse /data/dataset.json once at startup into g_items[]
static void load_dataset(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return;
    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (fsize <= 0 || fsize > 1048576) { fclose(fp); return; }

    char *buf = malloc((size_t)fsize + 1);
    if (!buf) { fclose(fp); return; }
    size_t read_bytes = fread(buf, 1, (size_t)fsize, fp);
    buf[read_bytes] = '\0';
    fclose(fp);

    char *p = buf;
    while (g_num_items < 64 && (p = strstr(p, "\"id\"")) != NULL) {
        DatasetItem *it = &g_items[g_num_items];
        memset(it, 0, sizeof(*it));

        char *colon = strchr(p + 4, ':');
        if (!colon) break;
        it->id = strtoll(colon + 1, &p, 10);

        char *nm = strstr(p, "\"name\"");
        if (nm && (nm = strchr(nm + 6, '"'))) {
            nm++;
            char *end = strchr(nm, '"');
            if (end) {
                size_t len = (size_t)(end - nm);
                if (len >= sizeof(it->name)) len = sizeof(it->name) - 1;
                memcpy(it->name, nm, len);
                it->name[len] = '\0';
                p = end + 1;
            }
        }

        char *cat = strstr(p, "\"category\"");
        if (cat && (cat = strchr(cat + 10, '"'))) {
            cat++;
            char *end = strchr(cat, '"');
            if (end) {
                size_t len = (size_t)(end - cat);
                if (len >= sizeof(it->category)) len = sizeof(it->category) - 1;
                memcpy(it->category, cat, len);
                it->category[len] = '\0';
                p = end + 1;
            }
        }

        char *pr = strstr(p, "\"price\"");
        if (pr && (pr = strchr(pr + 7, ':'))) {
            it->price = strtoll(pr + 1, &p, 10);
        }

        char *qt = strstr(p, "\"quantity\"");
        if (qt && (qt = strchr(qt + 10, ':'))) {
            it->quantity = strtoll(qt + 1, &p, 10);
        }

        char *ac = strstr(p, "\"active\"");
        if (ac && (ac = strchr(ac + 8, ':'))) {
            while (*++ac == ' ' || *ac == '\t' || *ac == '\n' || *ac == '\r');
            it->active = (*ac == 't');
            p = ac;
        }

        char *tg = strstr(p, "\"tags\"");
        if (tg && (tg = strchr(tg + 6, '['))) {
            char *end = strchr(tg, ']');
            if (end) {
                size_t len = (size_t)(end - tg + 1);
                if (len >= sizeof(it->tags_raw)) len = sizeof(it->tags_raw) - 1;
                memcpy(it->tags_raw, tg, len);
                it->tags_raw[len] = '\0';
                p = end + 1;
            }
        } else {
            strcpy(it->tags_raw, "[]");
        }

        char *rt = strstr(p, "\"rating\"");
        if (rt) {
            char *sc = strstr(rt, "\"score\"");
            if (sc && (sc = strchr(sc + 7, ':'))) it->rating_score = strtoll(sc + 1, NULL, 10);
            char *ct = strstr(rt, "\"count\"");
            if (ct && (ct = strchr(ct + 7, ':'))) {
                it->rating_count = strtoll(ct + 1, &p, 10);
            }
        }

        g_num_items++;
    }
    free(buf);
}

// GET /pipeline -> 200 OK
HandlerState handle_pipeline(CwebContext* ctx) {
    send_text(ctx, 200, "ok");
    return DB_DONE;
}

// GET /baseline11?a=13&b=42 -> "55"
HandlerState handle_baseline_get(CwebContext* ctx) {
    char a_str[32], b_str[32], out[64];
    long long a = 0, b = 0;

    if (get_query_param(ctx, "a", a_str, sizeof(a_str)) == 0) a = strtoll(a_str, NULL, 10);
    if (get_query_param(ctx, "b", b_str, sizeof(b_str)) == 0) b = strtoll(b_str, NULL, 10);

    snprintf(out, sizeof(out), "%lld", a + b);
    send_text(ctx, 200, out);
    return DB_DONE;
}

// POST /baseline11?a=13&b=42 (body: "10") -> "65"
HandlerState handle_baseline_post(CwebContext* ctx) {
    char a_str[32], b_str[32], out[64];
    long long a = 0, b = 0, body_val = 0;

    if (get_query_param(ctx, "a", a_str, sizeof(a_str)) == 0) a = strtoll(a_str, NULL, 10);
    if (get_query_param(ctx, "b", b_str, sizeof(b_str)) == 0) b = strtoll(b_str, NULL, 10);
    if (ctx->request.body) body_val = strtoll(ctx->request.body, NULL, 10);

    snprintf(out, sizeof(out), "%lld", a + b + body_val);
    send_text(ctx, 200, out);
    return DB_DONE;
}

// GET /json/:count?m=2 -> JSON serialization + gzip/br compression
HandlerState handle_json_comp(CwebContext* ctx) {
    int count = 50;
    if (ctx->request.num_params >= 1 && ctx->request.path_params[0].len > 0 &&
        ctx->request.path_params[0].len < 16) {
        char c_str[16];
    memcpy(c_str, ctx->request.path_params[0].str, (size_t)ctx->request.path_params[0].len);
    c_str[ctx->request.path_params[0].len] = '\0';
    count = atoi(c_str);
        }
        if (count < 1) count = 1;
        if (count > g_num_items) count = g_num_items;

        long long m = 1;
    char m_str[32];
    if (get_query_param(ctx, "m", m_str, sizeof(m_str)) == 0) {
        m = strtoll(m_str, NULL, 10);
    }

    char raw_json[16384];
    size_t pos = 0;
    pos += (size_t)snprintf(raw_json + pos, sizeof(raw_json) - pos, "{\"items\":[");

    for (int i = 0; i < count; i++) {
        if (i > 0) raw_json[pos++] = ',';
        const DatasetItem *it = &g_items[i];
        long long total = it->price * it->quantity * m;
        int w = snprintf(
            raw_json + pos, sizeof(raw_json) - pos,
                         "{\"id\":%lld,\"name\":\"%s\",\"category\":\"%s\",\"price\":%lld,"
                         "\"quantity\":%lld,\"active\":%s,\"tags\":%s,"
                         "\"rating\":{\"score\":%lld,\"count\":%lld},\"total\":%lld}",
                         it->id, it->name, it->category, it->price,
                         it->quantity, it->active ? "true" : "false", it->tags_raw,
                         it->rating_score, it->rating_count, total
        );
        if (w > 0) pos += (size_t)w;
    }
    pos += (size_t)snprintf(raw_json + pos, sizeof(raw_json) - pos, "],\"count\":%d}", count);

    const char *ae = get_header(ctx, "Accept-Encoding");
    if (ae) {
        uint8_t comp_buf[16384];
        if (strstr(ae, "br")) {
            size_t encoded_size = sizeof(comp_buf);
            if (BrotliEncoderCompress(1, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_TEXT,
                pos, (const uint8_t*)raw_json,
                                      &encoded_size, comp_buf) == BROTLI_TRUE) {
                add_header(ctx, "Content-Encoding", "br");
            send_bytes(ctx, 200, "application/json", comp_buf, encoded_size);
            return DB_DONE;
                                      }
        } else if (strstr(ae, "gzip")) {
            z_stream zs;
            memset(&zs, 0, sizeof(zs));
            if (deflateInit2(&zs, 1, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK) {
                zs.next_in   = (Bytef*)raw_json;
                zs.avail_in  = (uInt)pos;
                zs.next_out  = comp_buf;
                zs.avail_out = sizeof(comp_buf);
                if (deflate(&zs, Z_FINISH) == Z_STREAM_END) {
                    size_t gz_len = zs.total_out;
                    deflateEnd(&zs);
                    add_header(ctx, "Content-Encoding", "gzip");
                    send_bytes(ctx, 200, "application/json", comp_buf, gz_len);
                    return DB_DONE;
                }
                deflateEnd(&zs);
            }
        }
    }

    send_bytes(ctx, 200, "application/json", raw_json, pos);
    return DB_DONE;
}

HandlerState handle_ws(CwebContext* ctx) {
    if (!ctx->is_websocket) {
        upgrade_to_websocket(ctx);
        return DB_DONE;
    }
    send_ws_text(ctx, ctx->ws_payload);
    return DB_DONE;
}

// GET /async-db?min=10&max=50&limit=50
HandlerState handle_async_db(CwebContext* ctx) {
    switch (ctx->handler_step) {
        case 0: {
            char min_str[32] = "10";
            char max_str[32] = "50";
            char limit_str[32] = "50";

            get_query_param(ctx, "min", min_str, sizeof(min_str));
            get_query_param(ctx, "max", max_str, sizeof(max_str));
            get_query_param(ctx, "limit", limit_str, sizeof(limit_str));

            long long lim = strtoll(limit_str, NULL, 10);
            if (lim < 1) lim = 1;
            if (lim > 50) lim = 50;
            snprintf(limit_str, sizeof(limit_str), "%lld", lim);

            const char* params[3] = { min_str, max_str, limit_str };

            int err = db_query(ctx,
                               "SELECT id, name, category, price, quantity, active, "
                               "tags, rating_score, rating_count "
                               "FROM items WHERE price BETWEEN $1::int4 AND $2::int4 LIMIT $3::int4",
                               3, params);

            if (err == -1) {
                if (queue_db_request(ctx) == -1) {
                    send_error(ctx, 503, "Database queue full");
                    return DB_DONE;
                }
                return DB_QUEUED;
            }

            ctx->handler_step = 1;
            return DB_WAIT;
        }

        case 1: {
            if (!ctx->db_result || PQresultStatus(ctx->db_result) != PGRES_TUPLES_OK) {
                send_error(ctx, 500, "Database query failed");
                return DB_DONE;
            }

            int rows = PQntuples(ctx->db_result);
            char json_buf[16384];
            size_t pos = 0;

            pos += (size_t)snprintf(json_buf + pos, sizeof(json_buf) - pos, "{\"items\":[");

            for (int i = 0; i < rows; i++) {
                if (i > 0 && pos < sizeof(json_buf) - 1) {
                    json_buf[pos++] = ',';
                }

                const char* id_val     = PQgetvalue(ctx->db_result, i, 0);
                const char* name_val   = PQgetvalue(ctx->db_result, i, 1);
                const char* cat_val    = PQgetvalue(ctx->db_result, i, 2);
                const char* price_val  = PQgetvalue(ctx->db_result, i, 3);
                const char* qty_val    = PQgetvalue(ctx->db_result, i, 4);
                const char* active_val = PQgetvalue(ctx->db_result, i, 5);
                const char* tags_json  = PQgetvalue(ctx->db_result, i, 6);
                const char* r_score    = PQgetvalue(ctx->db_result, i, 7);
                const char* r_count    = PQgetvalue(ctx->db_result, i, 8);

                bool is_active = (active_val && (active_val[0] == 't' || active_val[0] == '1'));
                if (!tags_json || tags_json[0] == '\0') tags_json = "[]";

                int written = snprintf(
                    json_buf + pos, sizeof(json_buf) - pos,
                                       "{\"id\":%s,\"name\":\"%s\",\"category\":\"%s\",\"price\":%s,"
                                       "\"quantity\":%s,\"active\":%s,\"tags\":%s,"
                                       "\"rating\":{\"score\":%s,\"count\":%s}}",
                                       id_val, name_val, cat_val, price_val,
                                       qty_val, is_active ? "true" : "false", tags_json,
                                       r_score, r_count
                );
                if (written > 0) pos += (size_t)written;
            }

            snprintf(json_buf + pos, sizeof(json_buf) - pos, "],\"count\":%d}", rows);
            send_json(ctx, 200, json_buf);
            return DB_DONE;
        }
    }
    return DB_DONE;
}

int main(void) {
    load_dataset("/data/dataset.json");

    insert_route(GET, "/pipeline", handle_pipeline);
    insert_route(GET, "/baseline11", handle_baseline_get);
    insert_route(POST, "/baseline11", handle_baseline_post);
    insert_route(GET, "/json/:count", handle_json_comp);
    insert_route(GET, "/ws", handle_ws);
    insert_route(GET, "/async-db", handle_async_db);

    const char* db_url = getenv("DATABASE_URL");
    if (!db_url) db_url = getenv("DB_URL");

    // Dynamically scale DB connections per worker based on allowed CPUs
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    int num_cores = 0;
    if (sched_getaffinity(0, sizeof(cpuset), &cpuset) == 0) {
        num_cores = CPU_COUNT(&cpuset);
    }
    if (num_cores <= 0) num_cores = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (num_cores <= 0) num_cores = 1;

    const char* max_conn_env = getenv("DATABASE_MAX_CONN");
    int max_total = max_conn_env ? atoi(max_conn_env) : 256;
    int conns_per_core = (max_total - 32) / num_cores;
    if (conns_per_core < 1) conns_per_core = 1;
    if (conns_per_core > 8) conns_per_core = 8;

    return cweb_run_server(8080, db_url, db_url ? conns_per_core : 0);
}
