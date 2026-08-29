# Pinned, and that is the whole point of this entry. The floating
# 11.0-preview tag moved from preview.6 (published 2026-07-28) to preview.7
# (2026-08-28), and the 4.1M baseline was measured on 2026-08-09 -- i.e. on
# preview.6. Leaving it floating makes both arms of the comparison run today's
# runtime, which is what hid the variable the first time round.
# SDK and runtime version their tags differently: 11.0.1xx vs 11.0.0.
ARG DOTNET_SDK_TAG=11.0.100-preview.6
ARG DOTNET_RUNTIME_TAG=11.0.0-preview.6
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
