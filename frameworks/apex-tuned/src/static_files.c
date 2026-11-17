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
    struct timespec mtime;
    uint64_t path_hash;
    const char *mime_type;
    const char *content_encoding;
    bool in_use;
} static_cache_slot_t;

static char g_static_root_directory[512] = "/data/static";
static size_t g_static_root_length = sizeof("/data/static") - 1;
static __thread static_cache_slot_t s_thread_static_cache[MAX_STATIC_CACHE_SLOTS];

void static_files_init(const char *root_directory) {
    if (root_directory != NULL && *root_directory != '\0') {
        strncpy(g_static_root_directory, root_directory, sizeof(g_static_root_directory) - 1);
        g_static_root_directory[sizeof(g_static_root_directory) - 1] = '\0';
    }

    struct stat root_status;
    if ((stat(g_static_root_directory, &root_status) != 0 || !S_ISDIR(root_status.st_mode)) &&
        stat("./data/static", &root_status) == 0 && S_ISDIR(root_status.st_mode)) {
        memcpy(g_static_root_directory, "./data/static", sizeof("./data/static"));
    }
    g_static_root_length = strlen(g_static_root_directory);
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

static uint64_t hash_static_path(const char *path, size_t length) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (size_t index = 0; index < length; index++) {
        hash ^= (unsigned char)path[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static bool build_static_path(char *destination, size_t destination_size, const char *relative_path,
                              size_t relative_length, const char *suffix, size_t suffix_length,
                              size_t *out_path_length) {
    bool needs_separator = g_static_root_length > 0 && g_static_root_directory[g_static_root_length - 1] != '/';
    size_t path_length = g_static_root_length + (needs_separator ? 1 : 0) + relative_length + suffix_length;
    if (path_length >= destination_size) {
        return false;
    }

    char *cursor = destination;
    memcpy(cursor, g_static_root_directory, g_static_root_length);
    cursor += g_static_root_length;
    if (needs_separator) {
        *cursor++ = '/';
    }
    memcpy(cursor, relative_path, relative_length);
    cursor += relative_length;
    memcpy(cursor, suffix, suffix_length);
    cursor += suffix_length;
    *cursor = '\0';
    *out_path_length = path_length;
    return true;
}

static bool static_cache_lookup_candidate(const char *candidate_file_path, size_t candidate_path_length,
                                          const char *relative_path, const char *content_encoding,
                                          static_file_result_t *out_result) {
    struct stat file_status;
    if (stat(candidate_file_path, &file_status) != 0 || !S_ISREG(file_status.st_mode)) {
        return false;
    }

    uint64_t path_hash = hash_static_path(candidate_file_path, candidate_path_length);
    size_t start_index = (size_t)path_hash & (MAX_STATIC_CACHE_SLOTS - 1);
    static_cache_slot_t *target_slot = NULL;
    static_cache_slot_t *empty_slot = NULL;

    for (size_t probe = 0; probe < MAX_STATIC_CACHE_SLOTS; probe++) {
        static_cache_slot_t *slot = &s_thread_static_cache[(start_index + probe) & (MAX_STATIC_CACHE_SLOTS - 1)];
        if (!slot->in_use) {
            empty_slot = slot;
            break;
        }
        if (slot->path_hash == path_hash && strcmp(slot->full_path, candidate_file_path) == 0) {
            target_slot = slot;
            break;
        }
    }

    if (target_slot != NULL && target_slot->data != NULL &&
        target_slot->mtime.tv_sec == file_status.st_mtim.tv_sec &&
        target_slot->mtime.tv_nsec == file_status.st_mtim.tv_nsec &&
        target_slot->size == (size_t)file_status.st_size) {
        out_result->data = target_slot->data;
        out_result->size = target_slot->size;
        out_result->mime_type = target_slot->mime_type;
        out_result->content_encoding = target_slot->content_encoding;
        return true;
    }

    if (target_slot == NULL) {
        target_slot = empty_slot ? empty_slot : &s_thread_static_cache[start_index];
    }

    int file_descriptor = open(candidate_file_path, O_RDONLY);
    if (file_descriptor < 0) {
        return false;
    }

    size_t file_size = (size_t)file_status.st_size;
    if (target_slot->capacity < file_size + 1) {
        char *reallocated_buffer = realloc(target_slot->data, file_size + 1);
        if (!reallocated_buffer) {
            close(file_descriptor);
            return false;
        }
        target_slot->data = reallocated_buffer;
        target_slot->capacity = file_size + 1;
    }

    size_t total_bytes_read = 0;
    while (total_bytes_read < file_size) {
        ssize_t bytes_read = read(file_descriptor, target_slot->data + total_bytes_read, file_size - total_bytes_read);
        if (bytes_read <= 0) {
            break;
        }
        total_bytes_read += (size_t)bytes_read;
    }
    close(file_descriptor);

    if (total_bytes_read != file_size) {
        return false;
    }
    target_slot->data[file_size] = '\0';

    memcpy(target_slot->full_path, candidate_file_path, candidate_path_length + 1);
    target_slot->size = file_size;
    target_slot->mtime = file_status.st_mtim;
    target_slot->path_hash = path_hash;
    target_slot->mime_type = determine_mime_type(relative_path);
    target_slot->content_encoding = content_encoding;
    target_slot->in_use = true;

    out_result->data = target_slot->data;
    out_result->size = target_slot->size;
    out_result->mime_type = target_slot->mime_type;
    out_result->content_encoding = target_slot->content_encoding;
    return true;
}

static bool static_cache_lookup_variant(char *candidate_path, size_t candidate_path_size, const char *relative_path,
                                        size_t relative_length, const char *suffix, size_t suffix_length,
                                        const char *content_encoding, static_file_result_t *out_result) {
    size_t candidate_path_length;
    if (!build_static_path(candidate_path, candidate_path_size, relative_path, relative_length, suffix, suffix_length,
                           &candidate_path_length)) {
        return false;
    }
    return static_cache_lookup_candidate(candidate_path, candidate_path_length, relative_path, content_encoding,
                                         out_result);
}

bool static_cache_lookup(const char *relative_path, bool accept_brotli, bool accept_gzip,
                         static_file_result_t *out_result) {
    if (!relative_path || *relative_path == '\0' || strstr(relative_path, "..") != NULL) {
        return false;
    }

    while (*relative_path == '/') {
        relative_path++;
    }

    size_t relative_length = strlen(relative_path);
    char candidate_path[512];

    if (accept_brotli && static_cache_lookup_variant(candidate_path, sizeof(candidate_path), relative_path,
                                                       relative_length, ".br", 3, "br", out_result)) {
        return true;
    }
    if (accept_gzip && static_cache_lookup_variant(candidate_path, sizeof(candidate_path), relative_path,
                                                    relative_length, ".gz", 3, "gzip", out_result)) {
        return true;
    }
    return static_cache_lookup_variant(candidate_path, sizeof(candidate_path), relative_path, relative_length, "", 0,
                                       NULL, out_result);
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
