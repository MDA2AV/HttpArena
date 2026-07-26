ARG BUILDER_IMAGE=ghcr.io/kartikey321/dart-zig-builder:sha-0ed2b90cc29c41b6069204d07626e01b5bf074f8
ARG BASE_IMAGE=ghcr.io/kartikey321/dart-zig-runtime:sha-0ed2b90cc29c41b6069204d07626e01b5bf074f8

FROM ${BUILDER_IMAGE} AS build

COPY frameworks/dart-zig/benchmark_http_server.dart /opt/dart-zig-sdk/dart-zig/lib/_httparena_benchmark_http_server.dart
RUN /opt/dart-zig-sdk/out/ReleaseX64/dart \
    /opt/dart-zig-sdk/pkg/vm/bin/gen_kernel.dart \
    --platform /opt/dart-zig-sdk/out/ReleaseX64/vm_platform.dill \
    --link-platform \
    --packages /opt/dart-zig-sdk/.dart_tool/package_config.json \
    -o /tmp/benchmark_http_server.dill \
    /opt/dart-zig-sdk/dart-zig/lib/_httparena_benchmark_http_server.dart
RUN /opt/dart-zig-sdk/out/ReleaseX64/dart \
    /opt/dart-zig-sdk/pkg/vm/bin/gen_kernel.dart \
    --aot \
    --platform /opt/dart-zig-sdk/out/ReleaseX64/vm_platform_stripped.dill \
    --link-platform \
    --packages /opt/dart-zig-sdk/.dart_tool/package_config.json \
    -o /tmp/benchmark_http_server_aot.dill \
    /opt/dart-zig-sdk/dart-zig/lib/_httparena_benchmark_http_server.dart
RUN /opt/dart-zig-sdk/out/ReleaseX64/gen_snapshot \
    --snapshot_kind=app-aot-elf \
    --elf=/tmp/benchmark_http_server_aot.so \
    /tmp/benchmark_http_server_aot.dill

FROM ${BASE_IMAGE}

COPY frameworks/dart-zig/entrypoint.sh /entrypoint.sh
COPY data/dataset.json /data/dataset.json
COPY --from=build /tmp/benchmark_http_server.dill /app/benchmark_http_server.dill
COPY --from=build /tmp/benchmark_http_server_aot.so /app/benchmark_http_server_aot.so
RUN chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/entrypoint.sh"]
