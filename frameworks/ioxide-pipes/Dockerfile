# Pinned rather than floating: a preview tag moving under the entry has changed
# its baseline number before, which is not something a tag should be able to do
# silently. SDK and runtime version their tags differently: 11.0.1xx vs 11.0.0.
ARG DOTNET_SDK_TAG=11.0.100-preview.7
ARG DOTNET_RUNTIME_TAG=11.0.0-preview.7
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS build
WORKDIR /source
COPY ioxide-pipes.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app/out

# ioxide drives io_uring through direct libc syscalls (no liburing). The bench
# harness runs containers with --security-opt seccomp=unconfined (required for
# io_uring_setup/io_uring_enter); engine="io_uring" makes validate.sh enable it.
ARG DOTNET_RUNTIME_TAG
FROM mcr.microsoft.com/dotnet/runtime:${DOTNET_RUNTIME_TAG}
WORKDIR /app
COPY --from=build /app/out ./
EXPOSE 8080
ENTRYPOINT ["dotnet", "ioxide-pipes.dll"]
