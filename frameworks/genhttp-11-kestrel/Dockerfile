FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY genhttp.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0

ADD https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb /packages-microsoft-prod.deb

RUN dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app .

EXPOSE 8080 8081 8082 8443/tcp 8443/udp
ENTRYPOINT ["dotnet", "genhttp.dll"]
