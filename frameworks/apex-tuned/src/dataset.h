#pragma once

#include "common.h"
#include <brotli/encode.h>
#include <isa-l/igzip_lib.h>
#include <libdeflate.h>
#include <zlib.h>

typedef struct {
    int64_t id;
    int64_t price;
    int64_t quantity;
    int64_t base_total;
    int64_t score;
    int64_t count;
    bool active;
    char *name;
    char *category;
    char **tags;
    size_t num_tags;

    char *prefix;
    size_t prefix_len;
} dataset_item_t;

bool dataset_load(const char *path);
size_t dataset_count(void);

size_t json_serialize(size_t count, int64_t multiplier, char *out_buf, size_t max_out);
size_t json_cached_payload(size_t count, int64_t multiplier, const char **out_payload);
size_t json_cached_http1_response(size_t count, int64_t multiplier, const char **out_response_start);

typedef struct json_gzip_cache_entry json_gzip_cache_entry_t;

typedef struct {
    char json_buf[WRITE_BUF_SIZE];
    char comp_buf[WRITE_BUF_SIZE];
    struct isal_zstream gzip_stream;
    struct libdeflate_compressor *gzip_compressor;
    z_stream zlib_stream;
    bool zlib_initialized;
    json_gzip_cache_entry_t *gzip_response_cache;
    size_t gzip_response_cache_size;
} worker_compress_t;

void compress_worker_init(worker_compress_t *wc);
void compress_worker_destroy(worker_compress_t *wc);

int compress_brotli(const char *in_buf, size_t in_len, char *out_buf, size_t max_out, size_t *out_len);
int compress_gzip(worker_compress_t *wc, char *in_buf, size_t in_len, char *out_buf, size_t max_out,
                   size_t *out_len);
size_t json_gzip_http1_response(worker_compress_t *wc, size_t count, int64_t multiplier, char *out_buf,
                                size_t max_out, const char **out_response_start);
size_t json_gzip_cached_http1_response(size_t count, int64_t multiplier, const char **out_response_start);
