#pragma once

#include "common.h"
#include <brotli/encode.h>
#include <zlib.h>

typedef struct {
    int64_t     id;
    int64_t     price;
    int64_t     quantity;
    int64_t     score;
    int64_t     count;
    bool        active;
    char       *name;
    char       *category;
    char      **tags;
    size_t      num_tags;

    char       *prefix;
    size_t      prefix_len;
} dataset_item_t;

bool dataset_load(const char *path);
size_t dataset_count(void);

size_t json_serialize(size_t count, int64_t multiplier, char *out_buf, size_t max_out);

typedef struct {
    char        json_buf[WRITE_BUF_SIZE];
    char        comp_buf[WRITE_BUF_SIZE];
    z_stream    zlib_stream;
    bool        zlib_initialized;
} worker_compress_t;

void compress_worker_init(worker_compress_t *wc);
void compress_worker_destroy(worker_compress_t *wc);

int compress_brotli(const char *in_buf, size_t in_len, char *out_buf, size_t max_out, size_t *out_len);
int compress_gzip(worker_compress_t *wc, const char *in_buf, size_t in_len, char *out_buf, size_t max_out, size_t *out_len);
