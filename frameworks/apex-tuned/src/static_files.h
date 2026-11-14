#pragma once

#include "common.h"
#include "router.h"

void static_files_init(const char *root_dir);
void static_file_handler(context_t *ctx);
