FROM mcr.microsoft.com/dotnet/sdk:11.0.100-preview.7 AS build
WORKDIR /src/app

# GenHTTP from source, not from nuget.org. The engine this entry exercises - TLS terminated in the
# engine, HTTP/2 and HTTP/3 - lives on the ioxide-0.4.161 branch (PR #887) and has no published
# preview yet. Pinned to the branch head at build time; swap genhttp.csproj back to
# PackageReferences once it ships.
#
# The :11.0.100-preview.5 SDK provides .NET 11 plus Roslyn 5.3+ for GenHTTP's MemoryView source
# generator.
RUN git clone --depth 1 --branch ioxide-0.4.161 \
        https://github.com/Kaliumhexacyanoferrat/GenHTTP.git /src/genhttp

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
