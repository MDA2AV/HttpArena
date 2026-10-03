/*
 * HttpArena entry for Mongoose (https://github.com/cesanta/mongoose).
 *
 * Mongoose is an embedded networking library: one `struct mg_mgr` drives a
 * single-threaded event loop, and everything on the wire - HTTP/1.1 parsing,
 * the WebSocket framing, the TLS record layer, the static file handler - comes
 * out of the library. This file supplies handlers and nothing else, which is
 * what an engine entry is supposed to be.
 *
 * Two things here are not handlers, and both are about getting a
 * single-threaded library onto a 64-thread box:
 *
 *   1. one process per logical CPU, each with its own mg_mgr and its own
 *      listening socket (see `spawn_workers`);
 *   2. SO_REUSEPORT on those sockets, which mongoose does not set itself
 *      (see the `socket` wrapper below).
 *
 * Endpoints, by profile:
 *   baseline / limited-conn / latency-*  GET+POST /baseline11?a=&b=
 *   async                                GET      /delay/{ms}
 *   json-tls                             GET      /json/{count}?m={mult}   :8081 TLS
 *   8gbit                                POST     /echo                    :8081 TLS
 *   static-tls                           GET      /static/...             :8081 TLS
 *   echo-ws*                             GET      /ws  (upgrade)
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include "mongoose.h"

#define PLAIN_PORT "8080"  /* h1 plaintext: baseline, async, websocket */
#define TLS_PORT   "8081"  /* h1 + TLS: json-tls, 8gbit, static-tls    */

#define STATIC_ROOT "/static=/data/static"
#define DATASET_PATH "/data/dataset.json"
#define CERT_PATH "/certs/server.crt"
#define KEY_PATH "/certs/server.key"

/* Poll timeout when nothing is waiting on a timer. Mongoose blocks in
 * epoll_wait for this long, so it is also the floor on how often an idle
 * worker wakes up - which latency-10k measures directly. Requests arriving on
 * a socket wake the loop immediately, so a long value costs nothing but idle
 * CPU. When /delay/{ms} responses are outstanding the loop drops to 1ms so the
 * deadline check below has millisecond resolution. */
#define POLL_IDLE_MS 100
#define POLL_TIMER_MS 1

/* ── SO_REUSEPORT ───────────────────────────────────────────────────────────
 *
 * Mongoose sets SO_REUSEADDR on a listening socket and stops there, so N
 * processes cannot bind :8080 between them - which is the only way to put a
 * single-threaded event loop on 64 cores. Rather than patch a pinned upstream
 * tarball, this interposes on socket(2): a definition in the executable wins
 * the dynamic linker's lookup over libc's, so mongoose's own call lands here.
 *
 * The flag is only honoured while a listener is being opened, so nothing else
 * in the process (an OpenSSL-internal socket, say) picks it up by accident. */
static int s_want_reuseport = 0;

int socket(int domain, int type, int protocol) {
  static int (*real_socket)(int, int, int);
  int fd;
  if (real_socket == NULL) {
    real_socket = (int (*)(int, int, int)) dlsym(RTLD_NEXT, "socket");
    if (real_socket == NULL) {
      fprintf(stderr, "mongoose: cannot resolve socket(2)\n");
      exit(1);
    }
  }
  fd = real_socket(domain, type, protocol);
  if (fd >= 0 && s_want_reuseport) {
    int on = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on)) != 0) {
      fprintf(stderr, "mongoose: SO_REUSEPORT failed\n");
      exit(1);
    }
  }
  return fd;
}

/* ── Dataset (json-tls) ─────────────────────────────────────────────────────
 *
 * /data/dataset.json is read and parsed once, before the workers fork, so the
 * 50 items are shared copy-on-write rather than parsed 64 times. Only the
 * parse is shared: every response is serialized from these fields on the
 * request that asked for it, with `total` computed against that request's
 * multiplier. `tags` is re-serialized once at load into a compact array, so
 * responses do not carry the source document's indentation - that is a
 * normalization of the input, not a pre-rendered response. */
struct item {
  long id, price, quantity, score, rcount;
  bool active;
  char *name;             /* unescaped, from mg_json_get_str */
  char *category;
  char *tags;             /* compact JSON array, e.g. ["sale","popular"] */
};

#define MAX_ITEMS 64
static struct item s_items[MAX_ITEMS];
static int s_nitems = 0;
static struct mg_str s_dataset;

static struct mg_str read_file(const char *path) {
  struct mg_str s = mg_file_read(&mg_fs_posix, path);
  if (s.buf == NULL) {
    fprintf(stderr, "mongoose: cannot read %s\n", path);
    exit(1);
  }
  return s;
}

/* The source document is pretty-printed, so the raw `tags` token carries its
 * indentation. Rebuild it from the parsed strings instead. */
static char *load_tags(int item) {
  char *out = mg_mprintf("[");
  for (int j = 0; j < 64; j++) {
    char path[64], *tag, *next;
    mg_snprintf(path, sizeof(path), "$[%d].tags[%d]", item, j);
    if ((tag = mg_json_get_str(s_dataset, path)) == NULL) break;
    next = mg_mprintf("%s%s%m", out, j > 0 ? "," : "", MG_ESC(tag));
    mg_free(tag);
    mg_free(out);
    out = next;
  }
  {
    char *closed = mg_mprintf("%s]", out);
    mg_free(out);
    return closed;
  }
}

static void load_dataset(void) {
  s_dataset = read_file(DATASET_PATH);
  for (int i = 0; i < MAX_ITEMS; i++) {
    char path[64];
    int toklen = 0;
    struct item *it = &s_items[i];
    mg_snprintf(path, sizeof(path), "$[%d]", i);
    if (mg_json_get(s_dataset, path, &toklen) < 0) break;
    mg_snprintf(path, sizeof(path), "$[%d].id", i);
    it->id = mg_json_get_long(s_dataset, path, 0);
    mg_snprintf(path, sizeof(path), "$[%d].price", i);
    it->price = mg_json_get_long(s_dataset, path, 0);
    mg_snprintf(path, sizeof(path), "$[%d].quantity", i);
    it->quantity = mg_json_get_long(s_dataset, path, 0);
    mg_snprintf(path, sizeof(path), "$[%d].rating.score", i);
    it->score = mg_json_get_long(s_dataset, path, 0);
    mg_snprintf(path, sizeof(path), "$[%d].rating.count", i);
    it->rcount = mg_json_get_long(s_dataset, path, 0);
    mg_snprintf(path, sizeof(path), "$[%d].active", i);
    it->active = false;
    mg_json_get_bool(s_dataset, path, &it->active);
    mg_snprintf(path, sizeof(path), "$[%d].name", i);
    it->name = mg_json_get_str(s_dataset, path);
    mg_snprintf(path, sizeof(path), "$[%d].category", i);
    it->category = mg_json_get_str(s_dataset, path);
    it->tags = load_tags(i);
    if (it->name == NULL || it->category == NULL) {
      fprintf(stderr, "mongoose: malformed item %d in %s\n", i, DATASET_PATH);
      exit(1);
    }
    s_nitems = i + 1;
  }
  if (s_nitems == 0) {
    fprintf(stderr, "mongoose: %s holds no items\n", DATASET_PATH);
    exit(1);
  }
}

/* %M printer: writes the whole /json body straight into the connection's send
 * buffer, so mg_http_reply can back-fill Content-Length without a staging
 * copy. */
static size_t print_json(mg_pfn_t out, void *arg, va_list *ap) {
  long count = va_arg(*ap, long), mult = va_arg(*ap, long);
  size_t n = mg_xprintf(out, arg, "{\"items\":[");
  for (long i = 0; i < count; i++) {
    const struct item *it = &s_items[i];
    n += mg_xprintf(
        out, arg,
        "%s{\"id\":%ld,\"name\":%m,\"category\":%m,\"price\":%ld,"
        "\"quantity\":%ld,\"active\":%s,\"tags\":%s,"
        "\"rating\":{\"score\":%ld,\"count\":%ld},\"total\":%ld}",
        i > 0 ? "," : "", it->id, MG_ESC(it->name), MG_ESC(it->category),
        it->price, it->quantity, it->active ? "true" : "false", it->tags,
        it->score, it->rcount, it->price * it->quantity * mult);
  }
  n += mg_xprintf(out, arg, "],\"count\":%ld}", count);
  return n;
}

/* ── Handlers ───────────────────────────────────────────────────────────────*/

/* Deferred /delay/{ms} state, parked in the 32 bytes mongoose reserves per
 * connection. A timer per request would mean one allocation per request and a
 * dangling pointer every time a client disconnects mid-wait; the poll loop
 * already visits every connection once per iteration, so the deadline is
 * checked there instead. */
struct delay {
  uint64_t due;   /* mg_millis() value at which the reply is owed */
  uint32_t ms;    /* the parsed parameter, echoed back as the body */
  uint32_t armed;
};

/* c->data is shared with mongoose: mg_http_serve_file parks the bytes still
 * owed on a static transfer in the LAST size_t of it (see static_cb in
 * http.c), so the delay state has to stay clear of that word. The two never
 * meet on one connection today - /delay is :8080 and /static is :8081 - but a
 * silent overlap would corrupt a file mid-send, so it is asserted rather than
 * assumed. The alignment assert is mongoose's own assumption too. */
_Static_assert(sizeof(struct delay) <= MG_DATA_SIZE - sizeof(size_t),
               "delay state must fit in mg_connection::data below static_cb's");
_Static_assert(offsetof(struct mg_connection, data) % 8 == 0,
               "mg_connection::data must be 8-byte aligned for struct delay");

static long s_pending;  /* outstanding delays in this worker */

/* mg_str_to_num refuses a string it cannot consume whole, so the slice is
 * trimmed first: a body arriving with a trailing newline is still a number. */
static long parse_long(struct mg_str s, long dflt) {
  uint64_t v;
  while (s.len > 0 && (s.buf[0] == ' ' || s.buf[0] == '\t' ||
                       s.buf[0] == '\r' || s.buf[0] == '\n'))
    s.buf++, s.len--;
  while (s.len > 0 && (s.buf[s.len - 1] == ' ' || s.buf[s.len - 1] == '\t' ||
                       s.buf[s.len - 1] == '\r' || s.buf[s.len - 1] == '\n'))
    s.len--;
  return mg_str_to_num(s, 10, &v, sizeof(v)) ? (long) v : dflt;
}

/* Sum of the a/b query parameters, plus the body on POST. mg_http_var hands
 * back a zero-copy slice of mongoose's own parsed query string. */
static void handle_baseline(struct mg_connection *c,
                            struct mg_http_message *hm) {
  long sum = parse_long(mg_http_var(hm->query, mg_str("a")), 0) +
             parse_long(mg_http_var(hm->query, mg_str("b")), 0);
  if (hm->body.len > 0) sum += parse_long(hm->body, 0);
  mg_http_reply(c, 200, "Content-Type: text/plain\r\n", "%ld", sum);
}

static void handle_delay(struct mg_connection *c, struct mg_http_message *hm,
                         struct mg_str ms_str) {
  long ms = parse_long(ms_str, -1);
  if (ms < 0) {
    mg_http_reply(c, 400, "Content-Type: text/plain\r\n", "bad delay");
  } else if (ms == 0) {
    mg_http_reply(c, 200, "Content-Type: text/plain\r\n", "0");
  } else {
    /* Leave c->is_resp set: mongoose stops parsing this connection until the
     * response is written, and re-enters the HTTP handler the moment it is. */
    struct delay *d = (struct delay *) c->data;
    d->due = mg_millis() + (uint64_t) ms;
    d->ms = (uint32_t) ms;
    d->armed = 1;
    s_pending++;
  }
  (void) hm;
}

static void handle_echo(struct mg_connection *c, struct mg_http_message *hm) {
  /* Headers then body: mg_http_reply formats through a per-character printer,
   * which is the wrong shape for a 100 KB payload. hm->body points into the
   * receive buffer and mg_send appends to the send buffer, so this does not
   * alias. */
  mg_printf(c,
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/octet-stream\r\n"
            "Content-Length: %lu\r\n\r\n",
            (unsigned long) hm->body.len);
  if (hm->body.len > 0) mg_send(c, hm->body.buf, hm->body.len);
  c->is_resp = 0;
}

static void handle_json(struct mg_connection *c, struct mg_http_message *hm,
                        struct mg_str count_str) {
  long count = parse_long(count_str, 0);
  long mult = parse_long(mg_http_var(hm->query, mg_str("m")), 1);
  if (count < 0) count = 0;
  if (count > s_nitems) count = s_nitems;
  mg_http_reply(c, 200, "Content-Type: application/json\r\n", "%M", print_json,
                count, mult);
}

static void handle_static(struct mg_connection *c,
                          struct mg_http_message *hm) {
  /* mongoose's own file handler, reading /data/static on every request: no
   * cache to go stale, and the mime overrides only cover the extensions its
   * built-in table does not carry. */
  struct mg_http_serve_opts opts;
  memset(&opts, 0, sizeof(opts));
  opts.root_dir = STATIC_ROOT;
  opts.mime_types = "woff2=font/woff2,woff=font/woff";
  mg_http_serve_dir(c, hm, &opts);
}

static void on_http_msg(struct mg_connection *c, struct mg_http_message *hm) {
  struct mg_str caps[2];
  if (mg_match(hm->uri, mg_str("/baseline11"), NULL)) {
    handle_baseline(c, hm);
  } else if (mg_match(hm->uri, mg_str("/delay/*"), caps)) {
    handle_delay(c, hm, caps[0]);
  } else if (mg_match(hm->uri, mg_str("/json/*"), caps)) {
    handle_json(c, hm, caps[0]);
  } else if (mg_match(hm->uri, mg_str("/echo"), NULL)) {
    handle_echo(c, hm);
  } else if (mg_match(hm->uri, mg_str("/static/#"), NULL)) {
    handle_static(c, hm);
  } else if (mg_match(hm->uri, mg_str("/ws"), NULL)) {
    /* No Sec-WebSocket-Key means mongoose answers 426 and drains, which is
     * what a plain GET /ws is supposed to get. */
    mg_ws_upgrade(c, hm, NULL);
  } else {
    mg_http_reply(c, 404, "Content-Type: text/plain\r\n", "not found");
  }
}

static void ev_handler(struct mg_connection *c, int ev, void *ev_data) {
  if (ev == MG_EV_HTTP_MSG) {
    on_http_msg(c, (struct mg_http_message *) ev_data);
  } else if (ev == MG_EV_WS_MSG) {
    struct mg_ws_message *wm = (struct mg_ws_message *) ev_data;
    mg_ws_send(c, wm->data.buf, wm->data.len, wm->flags & 0x0f);
  } else if (ev == MG_EV_POLL) {
    struct delay *d = (struct delay *) c->data;
    if (d->armed && *(uint64_t *) ev_data >= d->due) {
      d->armed = 0;
      s_pending--;
      mg_http_reply(c, 200, "Content-Type: text/plain\r\n", "%lu",
                    (unsigned long) d->ms);
    }
  } else if (ev == MG_EV_CLOSE) {
    struct delay *d = (struct delay *) c->data;
    if (d->armed) d->armed = 0, s_pending--;
  }
}

/* The TLS listener's handler: same routes, with a handshake in front. Mongoose
 * builds one SSL_CTX per accepted connection; the cert and key are read once
 * before the fork so at least the file I/O is not repeated. */
static struct mg_str s_cert, s_key;

static void tls_ev_handler(struct mg_connection *c, int ev, void *ev_data) {
  if (ev == MG_EV_ACCEPT) {
    struct mg_tls_opts opts;
    memset(&opts, 0, sizeof(opts));
    opts.cert = s_cert;
    opts.key = s_key;
    mg_tls_init(c, &opts);
  }
  ev_handler(c, ev, ev_data);
}

/* ── Workers ────────────────────────────────────────────────────────────────*/

static struct mg_connection *listen_on(struct mg_mgr *mgr, const char *url,
                                       mg_event_handler_t fn) {
  struct mg_connection *c;
  s_want_reuseport = 1;
  c = mg_http_listen(mgr, url, fn, NULL);
  s_want_reuseport = 0;
  if (c == NULL) {
    fprintf(stderr, "mongoose: cannot listen on %s\n", url);
    exit(1);
  }
  return c;
}

static void worker(int cpu) {
  struct mg_mgr mgr;
  if (cpu >= 0) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
  }
  mg_mgr_init(&mgr);
  listen_on(&mgr, "http://0.0.0.0:" PLAIN_PORT, ev_handler);
  listen_on(&mgr, "http://0.0.0.0:" TLS_PORT, tls_ev_handler);
  for (;;) mg_mgr_poll(&mgr, s_pending > 0 ? POLL_TIMER_MS : POLL_IDLE_MS);
}

/* One process per CPU in the container's affinity mask, each pinned to the CPU
 * it was given. --cpuset-cpus is what the profiles set, and it lands in that
 * mask, so latency-500k-8cpu gets 8 workers and baseline gets 64 without
 * anything being configured here. */
static int spawn_workers(void) {
  cpu_set_t set;
  int cpus[CPU_SETSIZE], n = 0, i, want;
  const char *env = getenv("MONGOOSE_WORKERS");
  pid_t parent = getpid();

  if (sched_getaffinity(0, sizeof(set), &set) != 0) CPU_ZERO(&set);
  for (i = 0; i < CPU_SETSIZE && n < CPU_SETSIZE; i++) {
    if (CPU_ISSET(i, &set)) cpus[n++] = i;
  }
  if (n == 0) cpus[n++] = -1;
  want = env != NULL ? atoi(env) : n;
  if (want < 1) want = 1;

  for (i = 1; i < want; i++) {
    pid_t pid = fork();
    if (pid < 0) {
      fprintf(stderr, "mongoose: fork failed after %d workers\n", i);
      break;
    }
    if (pid == 0) {
      /* docker stop signals PID 1 only; without this the children outlive the
       * parent and keep the port bound. */
      prctl(PR_SET_PDEATHSIG, SIGTERM);
      if (getppid() != parent) _exit(0);  /* parent died before prctl took */
      worker(cpus[i % n]);
      _exit(0);
    }
  }
  return cpus[0];
}

int main(void) {
  const char *cert = getenv("TLS_CERT"), *key = getenv("TLS_KEY");
  signal(SIGPIPE, SIG_IGN);
  mg_log_set(MG_LL_ERROR);

  load_dataset();
  s_cert = read_file(cert != NULL ? cert : CERT_PATH);
  s_key = read_file(key != NULL ? key : KEY_PATH);

  worker(spawn_workers());
  return 0;
}
