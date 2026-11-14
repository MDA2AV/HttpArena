#pragma once

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sched.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <time.h>

#define MAX_WORKERS         128
#define MAX_EVENTS          1024
#define MAX_CONNS_PER_WORKER 65536
#define READ_BUF_SIZE       (128 * 1024)
#define WRITE_BUF_SIZE      (512 * 1024)
#define MAX_HEADERS         64
#define MAX_PARAMS          16
#define MAX_STATIC_FILES    128

typedef struct {
    const char *ptr;
    size_t      len;
} str_view_t;

static inline bool view_eq(str_view_t v, const char *s) {
    size_t slen = strlen(s);
    return v.len == slen && memcmp(v.ptr, s, slen) == 0;
}

static inline bool view_case_eq(str_view_t v, const char *s) {
    size_t slen = strlen(s);
    return v.len == slen && strncasecmp(v.ptr, s, slen) == 0;
}

static inline bool parse_i64(const char *s, size_t len, int64_t *out) {
    if (!len) return false;
    size_t i = 0;
    int neg = 0;
    if (s[0] == '-') { neg = 1; i = 1; }
    else if (s[0] == '+') { i = 1; }
    if (i >= len) return false;
    int64_t v = 0;
    for (; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < '0' || c > '9') return false;
        v = v * 10 + (c - '0');
    }
    *out = neg ? -v : v;
    return true;
}

#if defined(__linux__)
#include <sys/prctl.h>
#endif

static inline size_t format_i64(char *buf, int64_t v) {
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    char tmp[24];
    size_t t = 0;
    uint64_t u;
    bool neg = false;
    if (v < 0) {
        neg = true;
        u = (uint64_t)-v;
    } else {
        u = (uint64_t)v;
    }
    static const char digits[201] =
        "0001020304050607080910111213141516171819"
        "2021222324252627282930313233343536373839"
        "4041424344454647484950515253545556575859"
        "6061626364656667686970717273747576777879"
        "8081828384858687888990919293949596979899";
    while (u >= 100) {
        uint64_t q = u / 100;
        uint32_t r = (uint32_t)(u - (q * 100));
        tmp[t++] = digits[r * 2 + 1];
        tmp[t++] = digits[r * 2];
        u = q;
    }
    if (u < 10) {
        tmp[t++] = (char)('0' + u);
    } else {
        uint32_t r = (uint32_t)u;
        tmp[t++] = digits[r * 2 + 1];
        tmp[t++] = digits[r * 2];
    }
    size_t out_len = 0;
    if (neg) buf[out_len++] = '-';
    for (size_t i = 0; i < t; i++) {
        buf[out_len++] = tmp[t - 1 - i];
    }
    return out_len;
}

static inline uint64_t clock_monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static inline uint64_t clock_monotonic_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

static inline void set_sock_opts(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &one, sizeof(one));
}
