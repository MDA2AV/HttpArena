FROM fedora:43 AS build

RUN set -ex; \
    dnf install -y --setopt=install_weak_deps=False \
        autoconf \
        automake \
        autoconf-archive \
        libtool \
        pkgconf-pkg-config \
        gcc \
        make \
        git \
        python3 \
        python3-docutils \
        python3-sphinx \
        pcre2-devel \
        jemalloc-devel \
        ncurses-devel \
        libedit-devel; \
    cd /tmp; \
    git clone --recurse-submodules --branch vinyl-cache-9.0.1 \
        https://code.vinyl-cache.org/vinyl-cache/vinyl-cache.git vinyl-cache

COPY vmod/ /tmp/vinyl-cache/vmod/

RUN set -ex; \
    cd /tmp/vinyl-cache; \
    ./autogen.sh; \
    ./configure --prefix=/usr --sbindir=/usr/bin; \
    make -j"$(nproc)"; \
    make install DESTDIR=/out

FROM fedora:43

RUN set -ex; \
    dnf install -y --setopt=install_weak_deps=False \
        gcc \
        pcre2 \
        jemalloc \
        libedit \
        ncurses-libs; \
    dnf clean all; \
    mkdir -p /var/lib/vinyl-cache/vinyld

COPY --from=build /out/ /
COPY default.vcl /etc/vinyl/default.vcl
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
