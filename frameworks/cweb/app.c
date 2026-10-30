#include <cweb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

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

HandlerState handle_ws(CwebContext* ctx) {
    if (!ctx->is_websocket) {
        // Step 1: Initial HTTP GET /ws handshake
        upgrade_to_websocket(ctx);
        return DB_DONE;
    }
    // Step 2: Connected WebSocket frame arrived -> Echo it back!
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
                // Pool exhausted: park request in CWEB's wait queue (keep handler_step = 0 for RESUME!)
                if (queue_db_request(ctx) == -1) {
                    send_error(ctx, 503, "Database queue full");
                    return DB_DONE;
                }
                return DB_QUEUED;
            }

            // Query dispatched on ctx->db_conn! Advance to step 1 and wait for POLLIN.
            ctx->handler_step = 1;
            return DB_WAIT;
        }

        case 1: {
            if (!ctx->db_result || PQresultStatus(ctx->db_result) != PGRES_TUPLES_OK) {
                send_error(ctx, 500, "Database query failed");
                return DB_DONE;
            }

            int rows = PQntuples(ctx->db_result);
            char json_buf[65536];
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
    insert_route(GET, "/pipeline", handle_pipeline);
    insert_route(GET, "/baseline11", handle_baseline_get);
    insert_route(POST, "/baseline11", handle_baseline_post);
    insert_route(GET, "/ws", handle_ws);
    insert_route(GET, "/async-db", handle_async_db);

    const char* db_url = getenv("DATABASE_URL");
    if (!db_url) db_url = getenv("DB_URL");

    int conns_per_core = 3;

    return cweb_run_server(8080, db_url, db_url ? conns_per_core : 0);
}
