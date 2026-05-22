# Build (managed / JIT — no AOT toolchain needed).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY riderdog.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release --no-self-contained \
    -p:GarbageCollectionAdaptationMode=1 \
    -o /app/out

# Runtime (glibc, includes the .NET runtime).
# liburing2 is required by the bundled liburingshim.so for io_uring syscalls.
FROM mcr.microsoft.com/dotnet/runtime:10.0
RUN apt-get update && apt-get install -y --no-install-recommends liburing2 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/out ./
EXPOSE 8080
ENTRYPOINT ["dotnet", "riderdog.dll"]
