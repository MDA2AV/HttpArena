#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <signal.h>
#include <unistd.h>
#include <sched.h>
#include <sys/wait.h>

#include <reactor.h>

/* ── helpers ─────────────────────────────────────────────────────── */

static int parse_int(const char *s, int len)
{
    int n = 0;
    for (int i = 0; i < len; i++)
    {
        if (s[i] < '0' || s[i] > '9')
            break;
        n = n * 10 + (s[i] - '0');
    }
    return n;
}

static int sum_query_params(const char *qs, int qs_len)
{
    int sum = 0;
    const char *end = qs + qs_len;
    const char *p = qs;

    while (p < end)
    {
        const char *eq = memchr(p, '=', end - p);
        if (!eq)
            break;
        eq++;
        const char *amp = memchr(eq, '&', end - eq);
        int vlen = amp ? (int)(amp - eq) : (int)(end - eq);
        sum += parse_int(eq, vlen);
        p = amp ? amp + 1 : end;
    }
    return sum;
}

/* ── request handler ─────────────────────────────────────────────── */

static void callback(reactor_event *event)
{
    server_request *request = (server_request *) event->data;
    const char *target = data_base(request->target);
    size_t target_size = data_size(request->target);
    const char *method = data_base(request->method);
    size_t method_size = data_size(request->method);

    /* GET /pipeline — fast path */
    if (target_size == 9 && memcmp(target, "/pipeline", 9) == 0)
    {
        server_ok(request, data_string("text/plain"), data_string("ok"));
        return;
    }

    /* /baseline11 — must start with /baseline11 */
    if (target_size >= 11 && memcmp(target, "/baseline11", 11) == 0)
    {
        int sum = 0;

        /* parse query string */
        const char *qmark = memchr(target, '?', target_size);
        if (qmark)
        {
            int qs_len = (int)(target_size - (qmark + 1 - target));
            sum = sum_query_params(qmark + 1, qs_len);
        }

        /* parse body for POST */
        if (method_size == 4 && memcmp(method, "POST", 4) == 0)
        {
            data content_length_val = http_field_lookup(
                request->fields, request->fields_count,
                data_string("Content-Length"));
            data transfer_encoding_val = http_field_lookup(
                request->fields, request->fields_count,
                data_string("Transfer-Encoding"));

            if (!data_empty(transfer_encoding_val) &&
                memmem(data_base(transfer_encoding_val),
                       data_size(transfer_encoding_val), "chunked", 7))
            {
                /* chunked: skip chunk size line, parse chunk data */
                data body = request->target; /* placeholder — we need raw body */
                /* For chunked encoding, the body after headers contains:
                   <chunk-size>\r\n<chunk-data>\r\n0\r\n\r\n
                   We need to find it in the stream data */
                data req_data = request->data;
                const char *body_base = data_base(req_data);
                size_t body_size = data_size(req_data);
                if (body_size > 0)
                {
                    /* Find chunk data: skip the chunk size line */
                    const char *crlf = memmem(body_base, body_size, "\r\n", 2);
                    if (crlf)
                    {
                        const char *chunk_data = crlf + 2;
                        size_t remaining = body_size - (chunk_data - body_base);
                        const char *chunk_end = memmem(chunk_data, remaining, "\r\n", 2);
                        int chunk_len = chunk_end ? (int)(chunk_end - chunk_data) : (int)remaining;
                        if (chunk_len > 0)
                            sum += parse_int(chunk_data, chunk_len);
                    }
                }
            }
            else if (!data_empty(content_length_val))
            {
                /* Content-Length body */
                int cl = parse_int(data_base(content_length_val),
                                   (int)data_size(content_length_val));
                data req_data = request->data;
                const char *body_base = data_base(req_data);
                size_t body_size = data_size(req_data);
                if (cl > 0 && body_size > 0)
                {
                    int blen = cl < (int)body_size ? cl : (int)body_size;
                    sum += parse_int(body_base, blen);
                }
            }
        }

        char body_buf[16];
        int body_len = snprintf(body_buf, sizeof(body_buf), "%d", sum);
        server_ok(request, data_string("text/plain"),
                  data_construct(body_buf, body_len));
        return;
    }

    server_not_found(request);
}

static void run_worker(int cpu)
{
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    sched_setaffinity(0, sizeof(cpuset), &cpuset);

    server s;
    reactor_construct();
    server_construct(&s, callback, &s);
    server_open(&s,
                net_socket(net_resolve("0.0.0.0", "8080", AF_INET, SOCK_STREAM, AI_PASSIVE)),
                NULL);
    reactor_loop();
    server_destruct(&s);
    reactor_destruct();
}

int main(void)
{
    int cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (cpus < 1) cpus = 1;

    fprintf(stderr, "libreactor: spawning %d workers on :8080\n", cpus);

    for (int i = 1; i < cpus; i++)
    {
        pid_t pid = fork();
        if (pid == 0)
        {
            run_worker(i);
            _exit(0);
        }
    }

    run_worker(0);

    /* wait for children (shouldn't reach here) */
    while (wait(NULL) > 0);
    return 0;
}
