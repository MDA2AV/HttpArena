# NativeAOT build — produces a single native binary (no .NET runtime at runtime).
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
RUN apt-get update && apt-get install -y --no-install-recommends clang zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY minima-sync.csproj ./
RUN dotnet restore -r linux-x64
COPY . .
RUN dotnet publish -c Release -r linux-x64 -p:PublishAot=true -o /app/out

FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /app/out/minima-sync /server
EXPOSE 8080
ENTRYPOINT ["/server"]
