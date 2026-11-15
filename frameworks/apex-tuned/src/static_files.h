#pragma once

#include "common.h"
#include "router.h"

#include <stdbool.h>
#include <stddef.h>

typedef struct static_file_result_s {
    const char *data;
    size_t size;
    const char *mime_type;
    const char *content_encoding;
} static_file_result_t;

void static_files_init(const char *root_directory);
void static_file_handler(context_t *context);
bool static_cache_lookup(const char *relative_path, bool accept_brotli, bool accept_gzip,
                         static_file_result_t *out_result);
