FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app
COPY frameworks/oxpecker/ .
# Drop any host build output that came along with the copy; the SDK image has
# to restore for linux-x64 itself.
RUN rm -rf bin obj

# The benchmark's static assets become static web assets of the project, so the
# SDK emits an endpoint manifest for them at publish time — precomputed content
# types, lengths and ETags, plus gzip/brotli variants on disk next to the
# originals. /data/static is still mounted at runtime and holds the same files.
COPY data/static/ wwwroot/static/

RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:10.0

ADD https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb /packages-microsoft-prod.deb

RUN dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080 8081 8082 8443/tcp 8443/udp

ENTRYPOINT ["dotnet", "HttpArena.Oxpecker.dll"]
