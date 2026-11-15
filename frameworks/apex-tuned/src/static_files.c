#include "static_files.h"

static char g_static_root[512] = "/data/static";

void static_files_init(const char *root_dir) {
    if (root_dir && *root_dir) {
        strncpy(g_static_root, root_dir, sizeof(g_static_root) - 1);
    }
}

static const char* guess_mime_type(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return "application/octet-stream";
    if (strcmp(dot, ".html") == 0 || strcmp(dot, ".htm") == 0) return "text/html; charset=utf-8";
    if (strcmp(dot, ".css") == 0) return "text/css";
    if (strcmp(dot, ".js") == 0) return "application/javascript";
    if (strcmp(dot, ".json") == 0) return "application/json";
    if (strcmp(dot, ".png") == 0) return "image/png";
    if (strcmp(dot, ".jpg") == 0 || strcmp(dot, ".jpeg") == 0) return "image/jpeg";
    if (strcmp(dot, ".txt") == 0) return "text/plain";
    if (strcmp(dot, ".svg") == 0) return "image/svg+xml";
    return "application/octet-stream";
}

void static_file_handler(context_t *ctx) {
    request_t *req = ctx->req;
    response_t *res = ctx->res;

    if (req->num_route_params == 0 || req->route_params[0].len == 0) {
        res_set_status(res, 404);
        return;
    }

    char rel_path[256];
    size_t rlen = req->route_params[0].len;
    if (rlen >= sizeof(rel_path)) rlen = sizeof(rel_path) - 1;
    memcpy(rel_path, req->route_params[0].ptr, rlen);
    rel_path[rlen] = '\0';

    if (strstr(rel_path, "..")) {
        res_set_status(res, 403);
        return;
    }

    const char *mime = guess_mime_type(rel_path);

    bool client_wants_br = (req->accept_encoding.ptr && strcasestr(req->accept_encoding.ptr, "br") != NULL);
    bool client_wants_gz = (req->accept_encoding.ptr && strcasestr(req->accept_encoding.ptr, "gzip") != NULL);

    char full_path[512];
    const char *chosen_encoding = NULL;
    int fd = -1;

    if (client_wants_br) {
        snprintf(full_path, sizeof(full_path), "%s/%s.br", g_static_root, rel_path);
        fd = open(full_path, O_RDONLY);
        if (fd >= 0) {
            chosen_encoding = "br";
        }
    }

    if (fd < 0 && client_wants_gz) {
        snprintf(full_path, sizeof(full_path), "%s/%s.gz", g_static_root, rel_path);
        fd = open(full_path, O_RDONLY);
        if (fd >= 0) {
            chosen_encoding = "gzip";
        }
    }

    if (fd < 0) {
        snprintf(full_path, sizeof(full_path), "%s/%s", g_static_root, rel_path);
        fd = open(full_path, O_RDONLY);
    }

    if (fd < 0) {
        res_set_status(res, 404);
        return;
    }

    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        res_set_status(res, 404);
        return;
    }

    size_t file_sz = (size_t)st.st_size;
    char *buf = malloc(file_sz ? file_sz : 1);
    if (!buf) {
        close(fd);
        res_set_status(res, 500);
        return;
    }

    size_t rd = 0;
    while (rd < file_sz) {
        ssize_t n = read(fd, buf + rd, file_sz - rd);
        if (n <= 0) break;
        rd += n;
    }
    close(fd);

    res->status = 200;
    res->content_type = mime;
    res->content_encoding = chosen_encoding;
    res->body = buf;
    res->body_len = rd;
    res->body_needs_free = true;
}
