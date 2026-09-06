FROM mcr.microsoft.com/dotnet/sdk:11.0.100-preview.7 AS build
WORKDIR /src/app

# GenHTTP 11.0.0-preview.24 from nuget.org, the same preview the genhttp entry builds against. The
# ioxide engine branch (PR #887) that this entry used to clone is merged and ships in that preview.
# The preview.7 SDK provides .NET 11 plus the Roslyn GenHTTP's MemoryView source generator needs.
COPY genhttp.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish genhttp.csproj -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:11.0.0-preview.7
WORKDIR /app
COPY --from=build /app .

# 8080 h1, 8081 h1+TLS, 8082 h2c, 8443 h2 over TCP and h3 over QUIC (UDP)
EXPOSE 8080 8081 8082 8443 8443/udp
ENTRYPOINT ["dotnet", "genhttp.dll"]
