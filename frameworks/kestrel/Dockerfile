FROM mcr.microsoft.com/dotnet/sdk:11.0 AS build
WORKDIR /app
COPY . .
RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:11.0

# HTTP/3 needs msquic; without it the QUIC listener never comes up and the h3 profiles fail.
ADD https://packages.microsoft.com/config/ubuntu/26.04/packages-microsoft-prod.deb /packages-microsoft-prod.deb

RUN dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080 8081 8082 8443/tcp 8443/udp

ENTRYPOINT ["dotnet", "kestrel.dll"]
