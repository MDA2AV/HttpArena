FROM mcr.microsoft.com/dotnet/sdk:11.0 AS build
WORKDIR /src/app

COPY genhttp.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish genhttp.csproj -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:11.0
WORKDIR /app
COPY --from=build /app .

# 8080 h1, 8081 h1+TLS, 8082 h2c, 8443 h2 over TCP and h3 over QUIC (UDP)
EXPOSE 8080 8081 8082 8443 8443/udp
ENTRYPOINT ["dotnet", "genhttp.dll"]
