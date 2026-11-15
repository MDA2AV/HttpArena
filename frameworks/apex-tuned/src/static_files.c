#include "static_files.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_STATIC_CACHE_SLOTS 64

typedef struct static_cache_slot_s {
    char full_path[512];
    char *data;
    size_t size;
    size_t capacity;
    time_t mtime;
    const char *mime_type;
    const char *content_encoding;
    bool in_use;
} static_cache_slot_t;

static char g_static_root_directory[512] = "/data/static";
static __thread static_cache_slot_t s_thread_static_cache[MAX_STATIC_CACHE_SLOTS];

void static_files_init(const char *root_directory) {
    if (root_directory != NULL && *root_directory != '\0') {
        strncpy(g_static_root_directory, root_directory, sizeof(g_static_root_directory) - 1);
        g_static_root_directory[sizeof(g_static_root_directory) - 1] = '\0';
    }
}

static const char *determine_mime_type(const char *file_path) {
    const char *extension_dot = strrchr(file_path, '.');
    if (!extension_dot) {
        return "application/octet-stream";
    }

    if (strcmp(extension_dot, ".html") == 0 || strcmp(extension_dot, ".htm") == 0) {
        return "text/html; charset=utf-8";
    }
    if (strcmp(extension_dot, ".css") == 0) {
        return "text/css";
    }
    if (strcmp(extension_dot, ".js") == 0) {
        return "application/javascript";
    }
    if (strcmp(extension_dot, ".json") == 0) {
        return "application/json";
    }
    if (strcmp(extension_dot, ".png") == 0) {
        return "image/png";
    }
    if (strcmp(extension_dot, ".jpg") == 0 || strcmp(extension_dot, ".jpeg") == 0) {
        return "image/jpeg";
    }
    if (strcmp(extension_dot, ".txt") == 0) {
        return "text/plain";
    }
    if (strcmp(extension_dot, ".svg") == 0) {
        return "image/svg+xml";
    }
    if (strcmp(extension_dot, ".woff2") == 0) {
        return "font/woff2";
    }
    if (strcmp(extension_dot, ".webp") == 0) {
        return "image/webp";
    }

    return "application/octet-stream";
}

bool static_cache_lookup(const char *relative_path, bool accept_brotli, bool accept_gzip,
                         static_file_result_t *out_result) {
    if (!relative_path || *relative_path == '\0' || strstr(relative_path, "..") != NULL) {
        return false;
    }

    while (*relative_path == '/') {
        relative_path++;
    }

    typedef struct candidate_path_s {
        char path[512];
        const char *encoding;
    } candidate_path_t;

    candidate_path_t candidates[6];
    size_t candidate_count = 0;

    if (accept_brotli) {
        snprintf(candidates[candidate_count].path, sizeof(candidates[candidate_count].path), "%s/%s.br",
                 g_static_root_directory, relative_path);
        candidates[candidate_count++].encoding = "br";

        snprintf(candidates[candidate_count].path, sizeof(candidates[candidate_count].path), "./data/static/%s.br",
                 relative_path);
        candidates[candidate_count++].encoding = "br";
    }

    if (accept_gzip) {
        snprintf(candidates[candidate_count].path, sizeof(candidates[candidate_count].path), "%s/%s.gz",
                 g_static_root_directory, relative_path);
        candidates[candidate_count++].encoding = "gzip";

        snprintf(candidates[candidate_count].path, sizeof(candidates[candidate_count].path), "./data/static/%s.gz",
                 relative_path);
        candidates[candidate_count++].encoding = "gzip";
    }

    snprintf(candidates[candidate_count].path, sizeof(candidates[candidate_count].path), "%s/%s",
             g_static_root_directory, relative_path);
    candidates[candidate_count++].encoding = NULL;

    snprintf(candidates[candidate_count].path, sizeof(candidates[candidate_count].path), "./data/static/%s",
             relative_path);
    candidates[candidate_count++].encoding = NULL;

    for (size_t candidate_index = 0; candidate_index < candidate_count; candidate_index++) {
        const char *candidate_file_path = candidates[candidate_index].path;
        const char *candidate_encoding = candidates[candidate_index].encoding;

        struct stat file_status;
        if (stat(candidate_file_path, &file_status) != 0 || !S_ISREG(file_status.st_mode)) {
            continue;
        }

        // Search thread-local cache slot
        static_cache_slot_t *target_slot = NULL;
        static_cache_slot_t *empty_slot = NULL;

        for (size_t slot_index = 0; slot_index < MAX_STATIC_CACHE_SLOTS; slot_index++) {
            if (s_thread_static_cache[slot_index].in_use) {
                if (strcmp(s_thread_static_cache[slot_index].full_path, candidate_file_path) == 0) {
                    target_slot = &s_thread_static_cache[slot_index];
                    break;
                }
            } else if (!empty_slot) {
                empty_slot = &s_thread_static_cache[slot_index];
            }
        }

        if (target_slot != NULL && target_slot->data != NULL) {
            // Check if disk has changed (following the disk requirement)
            if (target_slot->mtime == file_status.st_mtime && target_slot->size == (size_t)file_status.st_size) {
                out_result->data = target_slot->data;
                out_result->size = target_slot->size;
                out_result->mime_type = target_slot->mime_type;
                out_result->content_encoding = target_slot->content_encoding;
                return true;
            }
        }

        // Cache miss or disk file changed: load file from disk into slot
        if (!target_slot) {
            target_slot = empty_slot ? empty_slot : &s_thread_static_cache[0];
        }

        int file_descriptor = open(candidate_file_path, O_RDONLY);
        if (file_descriptor < 0) {
            continue;
        }

        size_t file_size = (size_t)file_status.st_size;
        if (target_slot->capacity < file_size + 1) {
            size_t new_capacity = file_size + 1;
            char *reallocated_buffer = realloc(target_slot->data, new_capacity);
            if (!reallocated_buffer) {
                close(file_descriptor);
                continue;
            }
            target_slot->data = reallocated_buffer;
            target_slot->capacity = new_capacity;
        }

        ssize_t bytes_read = 0;
        size_t total_bytes_read = 0;
        while (total_bytes_read < file_size) {
            bytes_read = read(file_descriptor, target_slot->data + total_bytes_read, file_size - total_bytes_read);
            if (bytes_read <= 0) {
                break;
            }
            total_bytes_read += (size_t)bytes_read;
        }
        close(file_descriptor);

        if (total_bytes_read != file_size) {
            continue;
        }
        target_slot->data[file_size] = '\0';

        strncpy(target_slot->full_path, candidate_file_path, sizeof(target_slot->full_path) - 1);
        target_slot->full_path[sizeof(target_slot->full_path) - 1] = '\0';
        target_slot->size = file_size;
        target_slot->mtime = file_status.st_mtime;
        target_slot->mime_type = determine_mime_type(relative_path);
        target_slot->content_encoding = candidate_encoding;
        target_slot->in_use = true;

        out_result->data = target_slot->data;
        out_result->size = target_slot->size;
        out_result->mime_type = target_slot->mime_type;
        out_result->content_encoding = target_slot->content_encoding;
        return true;
    }

    return false;
}

void static_file_handler(context_t *context) {
    request_t *request = context->req;
    response_t *response = context->res;

    if (request->num_route_params == 0 || request->route_params[0].len == 0) {
        res_set_status(response, 404);
        return;
    }

    char relative_file_path[256];
    size_t path_length = request->route_params[0].len;
    if (path_length >= sizeof(relative_file_path)) {
        path_length = sizeof(relative_file_path) - 1;
    }
    memcpy(relative_file_path, request->route_params[0].ptr, path_length);
    relative_file_path[path_length] = '\0';

    if (strstr(relative_file_path, "..") != NULL) {
        res_set_status(response, 403);
        return;
    }

    bool client_supports_brotli =
        (request->accept_encoding.ptr && strcasestr(request->accept_encoding.ptr, "br") != NULL);
    bool client_supports_gzip =
        (request->accept_encoding.ptr && strcasestr(request->accept_encoding.ptr, "gzip") != NULL);

    static_file_result_t file_result;
    if (!static_cache_lookup(relative_file_path, client_supports_brotli, client_supports_gzip, &file_result)) {
        res_set_status(response, 404);
        return;
    }

    response->status = 200;
    response->content_type = file_result.mime_type;
    response->content_encoding = file_result.content_encoding;
    response->body = file_result.data;
    response->body_len = file_result.size;
    response->body_needs_free = false;
}
