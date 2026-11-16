#include "static_files.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_STATIC_CACHE_SLOTS 64
#define STATIC_REVALIDATE_INTERVAL_MS 1000

typedef struct static_cache_slot_s {
    char full_path[512];
    char *http1_response;
    char *data;
    size_t size;
    size_t http1_response_size;
    size_t capacity;
    struct timespec mtime;
    uint64_t path_hash;
    uint64_t last_stat_ms;
    const char *mime_type;
    const char *content_encoding;
    bool exists;
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

static void static_result_from_slot(const static_cache_slot_t *slot, static_file_result_t *out_result) {
    out_result->data = slot->data;
    out_result->size = slot->size;
    out_result->mime_type = slot->mime_type;
    out_result->content_encoding = slot->content_encoding;
    out_result->http1_response = slot->http1_response;
    out_result->http1_response_size = slot->http1_response_size;
}

static size_t build_static_http1_header(char *destination, size_t destination_size, const char *mime_type,
                                        const char *content_encoding, size_t file_size) {
    static const char status_line[] = "HTTP/1.1 200 OK\r\n";
    static const char content_type_prefix[] = "Content-Type: ";
    static const char content_encoding_prefix[] = "Content-Encoding: ";
    static const char content_length_prefix[] = "Content-Length: ";
    static const char connection_suffix[] = "Connection: keep-alive\r\n\r\n";

    if (file_size > INT64_MAX) {
        return 0;
    }

    char content_length[20];
    size_t content_length_size = format_i64(content_length, (int64_t)file_size);
    size_t mime_type_size = strlen(mime_type);
    size_t content_encoding_size = content_encoding ? strlen(content_encoding) : 0;
    size_t header_size = sizeof(status_line) - 1 + sizeof(content_type_prefix) - 1 + mime_type_size + 2 +
                         sizeof(content_length_prefix) - 1 + content_length_size + 2 +
                         sizeof(connection_suffix) - 1;
    if (content_encoding) {
        header_size += sizeof(content_encoding_prefix) - 1 + content_encoding_size + 2;
    }
    if (header_size > destination_size) {
        return 0;
    }

    char *cursor = destination;
    memcpy(cursor, status_line, sizeof(status_line) - 1);
    cursor += sizeof(status_line) - 1;
    memcpy(cursor, content_type_prefix, sizeof(content_type_prefix) - 1);
    cursor += sizeof(content_type_prefix) - 1;
    memcpy(cursor, mime_type, mime_type_size);
    cursor += mime_type_size;
    memcpy(cursor, "\r\n", 2);
    cursor += 2;
    if (content_encoding) {
        memcpy(cursor, content_encoding_prefix, sizeof(content_encoding_prefix) - 1);
        cursor += sizeof(content_encoding_prefix) - 1;
        memcpy(cursor, content_encoding, content_encoding_size);
        cursor += content_encoding_size;
        memcpy(cursor, "\r\n", 2);
        cursor += 2;
    }
    memcpy(cursor, content_length_prefix, sizeof(content_length_prefix) - 1);
    cursor += sizeof(content_length_prefix) - 1;
    memcpy(cursor, content_length, content_length_size);
    cursor += content_length_size;
    memcpy(cursor, "\r\n", 2);
    cursor += 2;
    memcpy(cursor, connection_suffix, sizeof(connection_suffix) - 1);
    cursor += sizeof(connection_suffix) - 1;
    return (size_t)(cursor - destination);
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
                                           uint64_t current_time_ms, static_file_result_t *out_result) {
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

    if (target_slot != NULL && current_time_ms - target_slot->last_stat_ms < STATIC_REVALIDATE_INTERVAL_MS) {
        if (target_slot->exists) {
            static_result_from_slot(target_slot, out_result);
            return true;
        }
        return false;
    }

    if (target_slot == NULL) {
        target_slot = empty_slot ? empty_slot : &s_thread_static_cache[start_index];
        memcpy(target_slot->full_path, candidate_file_path, candidate_path_length + 1);
        target_slot->path_hash = path_hash;
        target_slot->mime_type = determine_mime_type(relative_path);
        target_slot->content_encoding = content_encoding;
        target_slot->size = 0;
        target_slot->http1_response_size = 0;
        target_slot->data = NULL;
        target_slot->exists = false;
        target_slot->in_use = true;
    }
    target_slot->last_stat_ms = current_time_ms;

    struct stat file_status;
    if (stat(candidate_file_path, &file_status) != 0 || !S_ISREG(file_status.st_mode) || file_status.st_size < 0) {
        target_slot->size = 0;
        target_slot->http1_response_size = 0;
        target_slot->data = NULL;
        target_slot->exists = false;
        return false;
    }

    if (target_slot->exists && target_slot->mtime.tv_sec == file_status.st_mtim.tv_sec &&
        target_slot->mtime.tv_nsec == file_status.st_mtim.tv_nsec &&
        target_slot->size == (size_t)file_status.st_size) {
        static_result_from_slot(target_slot, out_result);
        return true;
    }

    int file_descriptor = open(candidate_file_path, O_RDONLY);
    if (file_descriptor < 0) {
        target_slot->exists = false;
        return false;
    }

    size_t file_size = (size_t)file_status.st_size;
    char header[256];
    size_t header_size = build_static_http1_header(header, sizeof(header), target_slot->mime_type,
                                                    target_slot->content_encoding, file_size);
    if (header_size == 0 || file_size > SIZE_MAX - header_size - 1) {
        close(file_descriptor);
        target_slot->exists = false;
        return false;
    }

    size_t response_size = header_size + file_size;
    if (target_slot->capacity < response_size + 1) {
        char *reallocated_buffer = realloc(target_slot->http1_response, response_size + 1);
        if (!reallocated_buffer) {
            close(file_descriptor);
            target_slot->exists = false;
            return false;
        }
        target_slot->http1_response = reallocated_buffer;
        target_slot->capacity = response_size + 1;
    }

    memcpy(target_slot->http1_response, header, header_size);
    size_t total_bytes_read = 0;
    while (total_bytes_read < file_size) {
        ssize_t bytes_read = read(file_descriptor, target_slot->http1_response + header_size + total_bytes_read,
                                  file_size - total_bytes_read);
        if (bytes_read < 0 && errno == EINTR) {
            continue;
        }
        if (bytes_read <= 0) {
            break;
        }
        total_bytes_read += (size_t)bytes_read;
    }
    close(file_descriptor);

    if (total_bytes_read != file_size) {
        target_slot->exists = false;
        return false;
    }
    target_slot->http1_response[response_size] = '\0';

    target_slot->data = target_slot->http1_response + header_size;
    target_slot->size = file_size;
    target_slot->http1_response_size = response_size;
    target_slot->mtime = file_status.st_mtim;
    target_slot->exists = true;

    static_result_from_slot(target_slot, out_result);
    return true;
}

static bool static_cache_lookup_variant(char *candidate_path, size_t candidate_path_size, const char *relative_path,
                                         size_t relative_length, const char *suffix, size_t suffix_length,
                                         const char *content_encoding, uint64_t current_time_ms,
                                         static_file_result_t *out_result) {
    size_t candidate_path_length;
    if (!build_static_path(candidate_path, candidate_path_size, relative_path, relative_length, suffix, suffix_length,
                           &candidate_path_length)) {
        return false;
    }
    return static_cache_lookup_candidate(candidate_path, candidate_path_length, relative_path, content_encoding,
                                          current_time_ms, out_result);
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
    uint64_t current_time_ms = clock_monotonic_ms();

    if (accept_brotli && static_cache_lookup_variant(candidate_path, sizeof(candidate_path), relative_path,
                                                       relative_length, ".br", 3, "br", current_time_ms,
                                                       out_result)) {
        return true;
    }
    if (accept_gzip && static_cache_lookup_variant(candidate_path, sizeof(candidate_path), relative_path,
                                                    relative_length, ".gz", 3, "gzip", current_time_ms,
                                                    out_result)) {
        return true;
    }
    return static_cache_lookup_variant(candidate_path, sizeof(candidate_path), relative_path, relative_length, "", 0,
                                        NULL, current_time_ms, out_result);
}

static bool header_value_contains_token(str_view_t header_value, const char *token, size_t token_size) {
    if (!header_value.ptr || header_value.len < token_size) {
        return false;
    }

    for (size_t offset = 0; offset <= header_value.len - token_size; offset++) {
        bool matches = true;
        for (size_t token_index = 0; token_index < token_size; token_index++) {
            unsigned char candidate = (unsigned char)header_value.ptr[offset + token_index];
            if ((candidate | 0x20U) != (unsigned char)token[token_index]) {
                matches = false;
                break;
            }
        }
        if (matches) {
            return true;
        }
    }
    return false;
}

size_t static_cached_http1_response(const request_t *request, const char **out_response_start) {
    if (!out_response_start) {
        return 0;
    }
    *out_response_start = NULL;

    if (!request || request->method != HTTP_METHOD_GET || !request->keep_alive || request->path.len <= 8 ||
        memcmp(request->path.ptr, "/static/", 8) != 0) {
        return 0;
    }

    size_t relative_path_size = request->path.len - 8;
    char relative_path[256];
    if (relative_path_size >= sizeof(relative_path)) {
        return 0;
    }
    memcpy(relative_path, request->path.ptr + 8, relative_path_size);
    relative_path[relative_path_size] = '\0';

    bool accept_brotli = header_value_contains_token(request->accept_encoding, "br", 2);
    bool accept_gzip = header_value_contains_token(request->accept_encoding, "gzip", 4);
    static_file_result_t result;
    if (!static_cache_lookup(relative_path, accept_brotli, accept_gzip, &result)) {
        return 0;
    }

    *out_response_start = result.http1_response;
    return result.http1_response_size;
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

    bool client_supports_brotli = header_value_contains_token(request->accept_encoding, "br", 2);
    bool client_supports_gzip = header_value_contains_token(request->accept_encoding, "gzip", 4);

    static_file_result_t file_result;
    if (!static_cache_lookup(relative_file_path, client_supports_brotli, client_supports_gzip, &file_result)) {
        res_set_status(response, 404);
        return;
    }

    response->status = 200;
    response->content_type = file_result.mime_type;
    response->content_encoding = file_result.content_encoding;
    response->body = request->method == HTTP_METHOD_HEAD ? NULL : file_result.data;
    response->body_len = file_result.size;
    response->body_needs_free = false;
}
