FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source
COPY ioxide-arena.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app/out

# ioxide drives io_uring through direct libc syscalls (no liburing). The bench
# harness runs containers with --security-opt seccomp=unconfined (required for
# io_uring_setup/enter); engine="io_uring" makes validate.sh enable it too.
FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
COPY --from=build /app/out ./
EXPOSE 8080 8081
ENTRYPOINT ["dotnet", "ioxide-arena.dll"]
