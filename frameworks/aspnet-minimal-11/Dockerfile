# aspnet-minimal on .NET 11 preview 7 with runtime async on. Same source as aspnet-minimal;
# only the runtime line and the csproj differ. Pinned to the preview rather than a floating
# 11.0 tag for the same reason the ioxide entry pins: a preview bump can move every number.
FROM mcr.microsoft.com/dotnet/sdk:11.0.100-preview.7 AS build
WORKDIR /app
COPY frameworks/aspnet-minimal-11/ .
RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:11.0.0-preview.7

# The 11.0 preview images are Ubuntu 26.04 (resolute), so libmsquic for HTTP/3 comes from
# the matching Microsoft feed rather than the Debian 12 one aspnet-minimal uses.
ADD https://packages.microsoft.com/config/ubuntu/26.04/packages-microsoft-prod.deb /packages-microsoft-prod.deb

RUN dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080 8081 8082 8443/tcp 8443/udp

ENTRYPOINT ["dotnet", "aspnet-minimal-11.dll"]
