/* HttpArena minimal bench server on top of libreactorng.
 *
 * Uses libreactor's built-in HTTP parser (session->request.{method,target,body})
 * so this file is just dispatch + integer arithmetic.
 *
 * Multi-process: one libreactor per logical CPU in the container's affinity
 * mask, each listening on its own SO_REUSEPORT socket so the kernel balances
 * accepted connections across workers.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <unistd.h>
#include <sched.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include <reactor.h>

/* Parse a leading signed integer. Skips whitespace, stops at the first
 * non-digit. Matches the contract of nginx/h2o reference implementations. */
static int64_t parse_int(const char *p, const char *end)
{
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    int neg = 0;
    if (p < end && *p == '-') { neg = 1; p++; }
    int64_t n = 0;
    while (p < end && *p >= '0' && *p <= '9') {
        n = n * 10 + (*p - '0');
        p++;
    }
    return neg ? -n : n;
}

/* Sum integer values across "k1=v1&k2=v2..." — ignores keys, non-integer
 * values silently skip. */
static int64_t sum_query(const char *p, size_t len)
{
    const char *end = p + len;
    int64_t sum = 0;
    while (p < end) {
        const char *eq = memchr(p, '=', end - p);
        if (!eq) break;
        const char *v = eq + 1;
        const char *amp = memchr(v, '&', end - v);
        const char *ve = amp ? amp : end;
        sum += parse_int(v, ve);
        p = amp ? amp + 1 : end;
    }
    return sum;
}

static void on_request(reactor_event_t *event)
{
    server_session_t *s = (server_session_t *) event->data;
    string_t method = s->request.method;
    string_t target = s->request.target;

    /* Split target at the first '?' to get path + query string. */
    const char *t = (const char *) data_base(target);
    size_t t_len = data_size(target);
    const char *q = memchr(t, '?', t_len);
    size_t path_len = q ? (size_t)(q - t) : t_len;
    const char *qs = q ? q + 1 : NULL;
    size_t qs_len = q ? (t_len - path_len - 1) : 0;

    /* Connection: close is NOT honored — libreactor keeps the session open
     * after the response, and the only teardown primitive it exposes
     * (server_disconnect → stream_close) is abortive: it closes before the
     * queued response bytes reach the socket. That causes the TCP
     * fragmentation validation checks to time out reading for an EOF that
     * never comes. Fixing it cleanly would need a write-completion hook in
     * libreactor's stream, which isn't in the public API. Known limitation. */

    if (path_len == 9 && memcmp(t, "/pipeline", 9) == 0) {
        server_plain(s, data_string("ok"), NULL, 0);
        return;
    }

    if (path_len == 11 && memcmp(t, "/baseline11", 11) == 0) {
        int64_t sum = qs ? sum_query(qs, qs_len) : 0;
        if (string_equal(method, string("POST"))) {
            const char *b = (const char *) data_base(s->request.body);
            size_t b_len = data_size(s->request.body);
            if (b_len > 0) sum += parse_int(b, b + b_len);
        }
        /* Stack buffer is safe: http_write_response copies via stream_allocate
         * before this handler returns to the event loop. */
        char buf[32];
        int n = snprintf(buf, sizeof(buf), "%lld", (long long) sum);
        server_plain(s, data(buf, n), NULL, 0);
        return;
    }

    if (path_len == 10 && memcmp(t, "/baseline2", 10) == 0) {
        int64_t sum = qs ? sum_query(qs, qs_len) : 0;
        char buf[32];
        int n = snprintf(buf, sizeof(buf), "%lld", (long long) sum);
        server_plain(s, data(buf, n), NULL, 0);
        return;
    }

    server_respond(s, string("404 Not Found"), string("text/plain"),
                   data_string("Not Found"), NULL, 0);
}

static int make_reuseport_socket(int port)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); exit(1); }
    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(s, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
        perror("bind"); exit(1);
    }
    if (listen(s, 4096) < 0) { perror("listen"); exit(1); }
    return s;
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);

    /* Respect Docker --cpuset-cpus via the affinity mask. sysconf() would
     * report the host CPU count which isn't what we want inside a pinned
     * container. */
    cpu_set_t cs;
    int workers = 1;
    if (sched_getaffinity(0, sizeof(cs), &cs) == 0) workers = CPU_COUNT(&cs);
    if (workers < 1) workers = 1;

    for (int i = 1; i < workers; i++) {
        pid_t pid = fork();
        if (pid < 0) { perror("fork"); break; }
        if (pid == 0) break;
    }

    int fd = make_reuseport_socket(8080);

    server_t server;
    reactor_construct();
    server_construct(&server, on_request, NULL);
    server_open_socket(&server, fd);
    reactor_loop();
    server_destruct(&server);
    reactor_destruct();
    return 0;
}
