#include "common.h"
#include "dataset.h"
#include "listener.h"
#include "server.h"
#include "static_files.h"
#include "tls.h"
#include "worker.h"

#include <signal.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#if defined(__linux__) && defined(__GLIBC__)
#include <malloc.h>
#endif

volatile sig_atomic_t g_running = 1;
static int g_num_workers = 1;
static worker_t *g_workers = NULL;

static void handle_sig(int sig) {
    (void)sig;
    g_running = 0;
}

static bool load_dataset(void) {
    const char *configured_path = getenv("DATASET_PATH");
    if (configured_path && dataset_load(configured_path)) {
        return true;
    }
    if ((!configured_path || strcmp(configured_path, "/data/dataset.json") != 0) &&
        dataset_load("/data/dataset.json")) {
        return true;
    }
    if (dataset_load("./data/dataset.json")) {
        return true;
    }

    char executable_path[PATH_MAX];
    ssize_t executable_path_length =
        readlink("/proc/self/exe", executable_path, sizeof(executable_path) - 1);
    if (executable_path_length > 0) {
        executable_path[executable_path_length] = '\0';
        char *filename = strrchr(executable_path, '/');
        static const char relative_dataset_path[] = "/data/dataset.json";
        if (filename) {
            size_t directory_length = (size_t)(filename - executable_path);
            if (directory_length + sizeof(relative_dataset_path) <= sizeof(executable_path)) {
                memcpy(executable_path + directory_length, relative_dataset_path,
                       sizeof(relative_dataset_path));
                if (dataset_load(executable_path)) {
                    return true;
                }
            }
        }
    }

    fprintf(stderr, "Failed to load dataset; set DATASET_PATH or place data/dataset.json next to server\n");
    return false;
}

int main(void) {
    signal(SIGINT, handle_sig);
    signal(SIGTERM, handle_sig);
    signal(SIGPIPE, SIG_IGN);

    cpu_set_t cpu_affinity_mask;
    int allowed_cpus[MAX_WORKERS];
    int num_allowed_cpus = 0;
    if (sched_getaffinity(0, sizeof(cpu_affinity_mask), &cpu_affinity_mask) == 0) {
        for (int cpu_index = 0; cpu_index < CPU_SETSIZE && num_allowed_cpus < MAX_WORKERS; cpu_index++) {
            if (CPU_ISSET(cpu_index, &cpu_affinity_mask)) {
                allowed_cpus[num_allowed_cpus++] = cpu_index;
            }
        }
    }
    if (num_allowed_cpus == 0) {
        long configured_cpus = sysconf(_SC_NPROCESSORS_ONLN);
        if (configured_cpus <= 0) {
            configured_cpus = 1;
        }
        if (configured_cpus > MAX_WORKERS) {
            configured_cpus = MAX_WORKERS;
        }
        for (int cpu_index = 0; cpu_index < configured_cpus; cpu_index++) {
            allowed_cpus[cpu_index] = cpu_index;
        }
        num_allowed_cpus = (int)configured_cpus;
    }
    g_num_workers = num_allowed_cpus;

    if (!load_dataset()) {
        return 1;
    }

    const char *static_root = getenv("STATIC_ROOT");
    if (!static_root) {
        static_root = "/data/static";
    }
    static_files_init(static_root);

    const char *cert_file = getenv("TLS_CERT");
    if (!cert_file) {
        cert_file = "/certs/server.crt";
    }
    const char *key_file = getenv("TLS_KEY");
    if (!key_file) {
        key_file = "/certs/server.key";
    }

    SSL_CTX *shared_ssl_ctx = tls_init_server_ctx(cert_file, key_file, false);
    if (!shared_ssl_ctx) {
        shared_ssl_ctx = tls_init_server_ctx("./certs/server.crt", "./certs/server.key", false);
    }

    SSL_CTX *shared_ssl_ctx_h2 = tls_init_server_ctx(cert_file, key_file, true);
    if (!shared_ssl_ctx_h2) {
        shared_ssl_ctx_h2 = tls_init_server_ctx("./certs/server.crt", "./certs/server.key", true);
    }

    g_workers = calloc((size_t)g_num_workers, sizeof(worker_t));
    if (!g_workers) {
        perror("calloc g_workers");
        return 1;
    }

    int port_http1 = 8080;
    const char *port_env = getenv("PORT");
    if (port_env) {
        int parsed_port = atoi(port_env);
        if (parsed_port > 0) {
            port_http1 = parsed_port;
        }
    }

    int port_tls = 8081;
    const char *tls_port_env = getenv("TLS_PORT");
    if (tls_port_env) {
        int parsed_port = atoi(tls_port_env);
        if (parsed_port > 0) {
            port_tls = parsed_port;
        }
    }

    int port_h2c = 8082;
    const char *h2c_port_env = getenv("H2C_PORT");
    if (h2c_port_env) {
        int parsed_port = atoi(h2c_port_env);
        if (parsed_port > 0) {
            port_h2c = parsed_port;
        }
    }

    int port_http2 = 8443;
    const char *h2_port_env = getenv("H2_PORT");
    if (!h2_port_env) {
        h2_port_env = getenv("H2PORT");
    }
    if (h2_port_env) {
        int parsed_port = atoi(h2_port_env);
        if (parsed_port > 0) {
            port_http2 = parsed_port;
        }
    }

    for (int worker_index = 0; worker_index < g_num_workers; worker_index++) {
        worker_t *worker = &g_workers[worker_index];
        if (worker_init(worker, worker_index, allowed_cpus[worker_index], shared_ssl_ctx, shared_ssl_ctx_h2, port_http1,
                        port_tls, port_h2c, port_http2) != 0) {
            fprintf(stderr, "Failed to initialize worker %d\n", worker_index);
            return 1;
        }
        pthread_create(&worker->thread, NULL, worker_thread_main, worker);
    }

    printf("[apex] Server listening on port %d (TLS: %d, H2C: %d, H2: %d) with %d workers\n", port_http1,
           shared_ssl_ctx ? port_tls : -1, port_h2c, shared_ssl_ctx_h2 ? port_http2 : -1, g_num_workers);
    fflush(stdout);

    for (int worker_index = 0; worker_index < g_num_workers; worker_index++) {
        pthread_join(g_workers[worker_index].thread, NULL);
    }

    if (shared_ssl_ctx) {
        tls_free_server_ctx(shared_ssl_ctx);
    }
    if (shared_ssl_ctx_h2) {
        tls_free_server_ctx(shared_ssl_ctx_h2);
    }

    free(g_workers);
    return 0;
}
