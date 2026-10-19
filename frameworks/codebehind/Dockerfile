FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY httparena-codebehind.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release --no-restore -o /app

# Framework-dependent on the ASP.NET runtime image: CodeBehind compiles the
# aspx views at startup against the shared ASP.NET Core assemblies.
FROM mcr.microsoft.com/dotnet/aspnet:10.0

# MsQuic, which Kestrel needs for HTTP/3.
ADD https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb /tmp/packages-microsoft-prod.deb
RUN dpkg -i /tmp/packages-microsoft-prod.deb && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic \
    && rm -rf /var/lib/apt/lists/*

# CodeBehind reads code_behind/ relative to the working directory.
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080 8081 8082 8443/tcp 8443/udp
ENTRYPOINT ["dotnet", "httparena-codebehind.dll"]
