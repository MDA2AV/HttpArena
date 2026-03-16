/* LD_PRELOAD shim: set SO_REUSEPORT on every SOCK_STREAM bind() */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/types.h>

typedef int (*bind_fn)(int, const struct sockaddr *, socklen_t);

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    int optval = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &optval, sizeof(optval));
    bind_fn real_bind = (bind_fn)dlsym(RTLD_NEXT, "bind");
    return real_bind(sockfd, addr, addrlen);
}
