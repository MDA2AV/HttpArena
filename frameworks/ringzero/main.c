#define _GNU_SOURCE
#include "engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <signal.h>
#include <unistd.h>

static engine_t g_eng;

static void on_signal(int sig)
{
    (void)sig;
    g_eng.running = 0;
}

/* ── minimal HTTP request parsing for /baseline11 ───────────── */

static int parse_int(const char *s, int len)
{
    int n = 0;
    for (int i = 0; i < len; i++) {
        if (s[i] < '0' || s[i] > '9') break;
        n = n * 10 + (s[i] - '0');
    }
    return n;
}

static int sum_query_params(const char *qs, int qs_len)
{
    int sum = 0;
    const char *end = qs + qs_len;
    const char *p = qs;

    while (p < end) {
        /* Find '=' */
        const char *eq = memchr(p, '=', end - p);
        if (!eq) break;
        eq++;
        /* Find end of value ('&' or end) */
        const char *amp = memchr(eq, '&', end - eq);
        int vlen = amp ? (int)(amp - eq) : (int)(end - eq);
        sum += parse_int(eq, vlen);
        p = amp ? amp + 1 : end;
    }
    return sum;
}

static const char PIPELINE_RESP[] =
    "HTTP/1.1 200 OK\r\n"
    "Server: ringzero\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 2\r\n"
    "\r\n"
    "ok";

static void bench_handler(conn_t *conn, uint8_t *buf, int len)
{
    const char *data = (const char *)buf;
    const char *data_end = data + len;

    /* Fast path: GET /pipeline — zero processing, handles pipelined requests */
    if (len >= 14 && memcmp(data, "GET /pipeline ", 14) == 0) {
        const char *p = data;
        while (p < data_end) {
            const char *next = memmem(p, data_end - p, "\r\n\r\n", 4);
            if (!next) break;
            conn_write(conn, (const uint8_t *)PIPELINE_RESP, sizeof(PIPELINE_RESP) - 1);
            p = next + 4;
        }
        conn_flush(conn);
        return;
    }

    /* Find end of request line */
    const char *req_end = memmem(data, len, "\r\n", 2);
    if (!req_end) goto bad;

    /* Find query string: after '?' before ' HTTP' */
    const char *qmark = memchr(data, '?', req_end - data);
    const char *space = memchr(qmark ? qmark : data, ' ', req_end - (qmark ? qmark : data));
    if (!space) space = req_end;

    int sum = 0;
    if (qmark && qmark < space)
        sum = sum_query_params(qmark + 1, (int)(space - qmark - 1));

    /* Find headers end */
    const char *hdr_end = memmem(data, len, "\r\n\r\n", 4);
    if (!hdr_end) goto bad;
    const char *body_start = hdr_end + 4;

    /* Check for Content-Length */
    int content_length = 0;
    int is_chunked = 0;
    const char *h = data;
    while (h < hdr_end) {
        const char *line_end = memmem(h, hdr_end - h + 2, "\r\n", 2);
        if (!line_end) break;
        int line_len = (int)(line_end - h);

        if (line_len > 16 && strncasecmp(h, "Content-Length: ", 16) == 0)
            content_length = parse_int(h + 16, line_len - 16);
        else if (line_len > 19 && strncasecmp(h, "Transfer-Encoding: ", 19) == 0)
            is_chunked = (memmem(h + 19, line_len - 19, "chunked", 7) != NULL);

        h = line_end + 2;
    }

    /* Parse body number */
    if (body_start < data_end) {
        const char *body = body_start;
        int body_len;

        if (is_chunked) {
            /* Skip chunk size line to get chunk data */
            const char *chunk_data = memmem(body, data_end - body, "\r\n", 2);
            if (chunk_data) {
                chunk_data += 2;
                const char *chunk_end = memmem(chunk_data, data_end - chunk_data, "\r\n", 2);
                if (chunk_end)
                    body_len = (int)(chunk_end - chunk_data);
                else
                    body_len = (int)(data_end - chunk_data);
                body = chunk_data;
            } else {
                body_len = 0;
            }
        } else {
            body_len = content_length;
            if (body_len > (int)(data_end - body))
                body_len = (int)(data_end - body);
        }

        if (body_len > 0)
            sum += parse_int(body, body_len);
    }

    /* Build response */
    char body_buf[16];
    int body_len = snprintf(body_buf, sizeof(body_buf), "%d", sum);

    char resp[256];
    int resp_len = snprintf(resp, sizeof(resp),
        "HTTP/1.1 200 OK\r\n"
        "Server: ringzero\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: %d\r\n"
        "\r\n"
        "%s",
        body_len, body_buf);

    conn_write(conn, (const uint8_t *)resp, resp_len);
    conn_flush(conn);
    return;

bad:
    ;
    static const char ERR[] =
        "HTTP/1.1 400 Bad Request\r\n"
        "Server: ringzero\r\n"
        "Content-Length: 0\r\n"
        "\r\n";
    conn_write(conn, (const uint8_t *)ERR, sizeof(ERR) - 1);
    conn_flush(conn);
}

int main(int argc, char **argv)
{
    int reactor_count = argc > 1 ? atoi(argv[1]) : 12;

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    memset(&g_eng, 0, sizeof(g_eng));
    engine_listen(&g_eng, "0.0.0.0", 8080, 65535, reactor_count, bench_handler);

    fprintf(stderr, "ringzero listening on :8080 with %d reactors\n", reactor_count);

    while (g_eng.running)
        sleep(1);

    engine_stop(&g_eng);
    return 0;
}
