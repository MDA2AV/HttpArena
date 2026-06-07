# Build (managed / JIT).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY minima-ws.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app/out

# Runtime. Minima drives io_uring through direct libc syscalls (no liburing /
# no native shim), so the stock runtime image suffices. The benchmark harness
# runs containers with --security-opt seccomp=unconfined, which is required for
# the io_uring_setup/enter syscalls.
FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
COPY --from=build /app/out ./
EXPOSE 8080
ENTRYPOINT ["dotnet", "minima-ws.dll"]
