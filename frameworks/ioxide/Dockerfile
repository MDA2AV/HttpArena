# Pinned rather than floating. 11.0-preview moved from preview.6 (2026-07-28)
# to preview.7 (2026-08-28) and took baseline-4096 from 4.11M to 3.90M with no
# change to this entry, which is not something a tag should be able to do
# silently. SDK and runtime version their tags differently: 11.0.1xx vs 11.0.0.
ARG DOTNET_SDK_TAG=11.0.100-preview.7
ARG DOTNET_RUNTIME_TAG=11.0.0-preview.7
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS build
WORKDIR /source
COPY ioxide-arena.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app/out

# ioxide drives io_uring through direct libc syscalls (no liburing). The bench
# harness runs containers with --security-opt seccomp=unconfined (required for
# io_uring_setup/enter); engine="io_uring" makes validate.sh enable it too.
ARG DOTNET_RUNTIME_TAG
FROM mcr.microsoft.com/dotnet/runtime:${DOTNET_RUNTIME_TAG}
WORKDIR /app
COPY --from=build /app/out ./
EXPOSE 8080 8081 8443 8443/udp
ENTRYPOINT ["dotnet", "ioxide-arena.dll"]
