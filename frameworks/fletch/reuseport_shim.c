/*
 * reuseport_shim.c — LD_PRELOAD shim that enables SO_REUSEPORT on every
 * TCP socket before bind().
 *
 * Without this, Dart's HttpServer.bind(shared: true) only shares the socket
 * within a single process (using an in-process FD registry). It does NOT set
 * SO_REUSEPORT, so a second OS process trying to bind the same port gets
 * EADDRINUSE.
 *
 * With this shim loaded, every call to bind() on a SOCK_STREAM socket
 * automatically gets SO_REUSEPORT. The Linux kernel (≥3.9) then distributes
 * incoming connections evenly across all N listening processes — the same
 * model as Node.js cluster.
 */
#define _GNU_SOURCE
#include <sys/socket.h>
#include <dlfcn.h>
#include <stddef.h>

typedef int (*bind_fn)(int, const struct sockaddr *, socklen_t);

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    static bind_fn real_bind = (bind_fn)0;
    if (!real_bind)
        real_bind = (bind_fn)dlsym(RTLD_NEXT, "bind");

    /* Set SO_REUSEPORT on TCP sockets so multiple OS processes can share
     * the same listening address:port.  SO_REUSEADDR was already set by
     * Dart; we only need to add REUSEPORT. */
    int type = 0, opt = 1;
    socklen_t tlen = sizeof(type);
    getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &type, &tlen);
    if (type == SOCK_STREAM)
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    return real_bind(sockfd, addr, addrlen);
}
