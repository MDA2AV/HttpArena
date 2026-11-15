#include "static_files.h"

static char g_static_root_directory[512] = "/data/static";

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

    return "application/octet-stream";
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

    const char *mime_type = determine_mime_type(relative_file_path);

    bool client_supports_brotli =
        (request->accept_encoding.ptr && strcasestr(request->accept_encoding.ptr, "br") != NULL);
    bool client_supports_gzip =
        (request->accept_encoding.ptr && strcasestr(request->accept_encoding.ptr, "gzip") != NULL);

    char full_file_path[512];
    const char *chosen_content_encoding = NULL;
    int file_descriptor = -1;

    if (client_supports_brotli) {
        snprintf(full_file_path, sizeof(full_file_path), "%s/%s.br", g_static_root_directory, relative_file_path);
        file_descriptor = open(full_file_path, O_RDONLY);
        if (file_descriptor >= 0) {
            chosen_content_encoding = "br";
        }
    }

    if (file_descriptor < 0 && client_supports_gzip) {
        snprintf(full_file_path, sizeof(full_file_path), "%s/%s.gz", g_static_root_directory, relative_file_path);
        file_descriptor = open(full_file_path, O_RDONLY);
        if (file_descriptor >= 0) {
            chosen_content_encoding = "gzip";
        }
    }

    if (file_descriptor < 0) {
        snprintf(full_file_path, sizeof(full_file_path), "%s/%s", g_static_root_directory, relative_file_path);
        file_descriptor = open(full_file_path, O_RDONLY);
    }

    if (file_descriptor < 0) {
        res_set_status(response, 404);
        return;
    }

    struct stat file_status;
    if (fstat(file_descriptor, &file_status) < 0 || !S_ISREG(file_status.st_mode)) {
        close(file_descriptor);
        res_set_status(response, 404);
        return;
    }

    size_t file_size = (size_t)file_status.st_size;
    char *read_buffer = malloc(file_size ? file_size : 1);
    if (!read_buffer) {
        close(file_descriptor);
        res_set_status(response, 500);
        return;
    }

    size_t bytes_read = 0;
    while (bytes_read < file_size) {
        ssize_t read_result = read(file_descriptor, read_buffer + bytes_read, file_size - bytes_read);
        if (read_result <= 0) {
            break;
        }
        bytes_read += (size_t)read_result;
    }
    close(file_descriptor);

    response->status = 200;
    response->content_type = mime_type;
    response->content_encoding = chosen_content_encoding;
    response->body = read_buffer;
    response->body_len = bytes_read;
    response->body_needs_free = true;
}
