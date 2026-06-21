FROM mcr.microsoft.com/dotnet/sdk:11.0-preview AS build
WORKDIR /app
COPY frameworks/aspnet-minimal-ioxide/ .
COPY data/static/ wwwroot/static/
RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:11.0-preview
WORKDIR /app
COPY --from=build /app/out .

# Plaintext h1 (8080), cleartext h2 (8082), HTTP/1.1-over-TLS via kTLS (8081). HTTP/2-over-TLS
# (8443) and HTTP/3 are not enabled yet — see the README. kTLS needs the host 'tls' kernel module.
EXPOSE 8080 8081 8082

ENTRYPOINT ["dotnet", "aspnet-minimal-ioxide.dll"]
