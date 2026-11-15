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

#define MAX_WORKERS 128
#define MAX_EVENTS 1024
#define MAX_CONNS_PER_WORKER 65536
#define READ_BUF_SIZE (128 * 1024)
#define WRITE_BUF_SIZE (512 * 1024)
#define MAX_HEADERS 64
#define MAX_PARAMS 16
#define MAX_STATIC_FILES 128

typedef struct {
    const char *ptr;
    size_t len;
} str_view_t;

static inline bool view_eq(str_view_t view, const char *expected_string) {
    size_t expected_length = strlen(expected_string);
    return view.len == expected_length && memcmp(view.ptr, expected_string, expected_length) == 0;
}

static inline bool view_case_eq(str_view_t view, const char *expected_string) {
    size_t expected_length = strlen(expected_string);
    return view.len == expected_length && strncasecmp(view.ptr, expected_string, expected_length) == 0;
}

static inline bool parse_i64(const char *string_buffer, size_t buffer_length, int64_t *out_parsed_value) {
    if (!buffer_length) {
        return false;
    }
    if (__builtin_expect(buffer_length == 1 && string_buffer[0] >= '0' && string_buffer[0] <= '9', 1)) {
        *out_parsed_value = string_buffer[0] - '0';
        return true;
    }
    if (buffer_length == 2 && string_buffer[0] >= '0' && string_buffer[0] <= '9' && string_buffer[1] >= '0' &&
        string_buffer[1] <= '9') {
        *out_parsed_value = (string_buffer[0] - '0') * 10 + (string_buffer[1] - '0');
        return true;
    }
    size_t cursor_index = 0;
    int sign_multiplier = 1;
    if (string_buffer[0] == '-') {
        sign_multiplier = -1;
        cursor_index = 1;
    } else if (string_buffer[0] == '+') {
        cursor_index = 1;
    }
    if (cursor_index >= buffer_length) {
        return false;
    }
    int64_t accumulated_value = 0;
    for (; cursor_index < buffer_length; cursor_index++) {
        unsigned char digit_char = (unsigned char)string_buffer[cursor_index];
        if (digit_char < '0' || digit_char > '9') {
            return false;
        }
        accumulated_value = accumulated_value * 10 + (digit_char - '0');
    }
    *out_parsed_value = sign_multiplier * accumulated_value;
    return true;
}

#if defined(__linux__)
#include <malloc.h>
#include <sys/prctl.h>
#endif

static inline size_t format_i64(char *destination_buffer, int64_t integer_value) {
    if (__builtin_expect(integer_value >= 0 && integer_value < 100, 1)) {
        if (integer_value < 10) {
            destination_buffer[0] = (char)('0' + integer_value);
            return 1;
        }
        destination_buffer[0] = (char)('0' + (integer_value / 10));
        destination_buffer[1] = (char)('0' + (integer_value % 10));
        return 2;
    }
    char temporary_buffer[24];
    size_t digits_written = 0;
    uint64_t unsigned_magnitude;
    bool is_negative = false;
    if (integer_value < 0) {
        is_negative = true;
        unsigned_magnitude = (uint64_t)-integer_value;
    } else {
        unsigned_magnitude = (uint64_t)integer_value;
    }
    static const char two_digit_lookup_table[201] = "0001020304050607080910111213141516171819"
                                                    "2021222324252627282930313233343536373839"
                                                    "4041424344454647484950515253545556575859"
                                                    "6061626364656667686970717273747576777879"
                                                    "8081828384858687888990919293949596979899";
    while (unsigned_magnitude >= 100) {
        uint64_t quotient = unsigned_magnitude / 100;
        uint32_t remainder = (uint32_t)(unsigned_magnitude - (quotient * 100));
        temporary_buffer[digits_written++] = two_digit_lookup_table[remainder * 2 + 1];
        temporary_buffer[digits_written++] = two_digit_lookup_table[remainder * 2];
        unsigned_magnitude = quotient;
    }
    if (unsigned_magnitude < 10) {
        temporary_buffer[digits_written++] = (char)('0' + unsigned_magnitude);
    } else {
        uint32_t remainder = (uint32_t)unsigned_magnitude;
        temporary_buffer[digits_written++] = two_digit_lookup_table[remainder * 2 + 1];
        temporary_buffer[digits_written++] = two_digit_lookup_table[remainder * 2];
    }
    size_t output_length = 0;
    if (is_negative) {
        destination_buffer[output_length++] = '-';
    }
    for (size_t index = 0; index < digits_written; index++) {
        destination_buffer[output_length++] = temporary_buffer[digits_written - 1 - index];
    }
    return output_length;
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

    // Enable TCP keepalive to detect and drop dead/idle sockets
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));

#if defined(TCP_KEEPIDLE)
    int keepidle = 15;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &keepidle, sizeof(keepidle));
#endif
#if defined(TCP_KEEPINTVL)
    int keepintvl = 5;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepintvl, sizeof(keepintvl));
#endif
#if defined(TCP_KEEPCNT)
    int keepcnt = 3;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &keepcnt, sizeof(keepcnt));
#endif
#if defined(TCP_USER_TIMEOUT)
    unsigned int user_timeout = 15000;
    setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &user_timeout, sizeof(user_timeout));
#endif
}
