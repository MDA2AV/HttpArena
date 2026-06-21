FROM mcr.microsoft.com/dotnet/sdk:11.0-preview AS build
WORKDIR /app
COPY frameworks/aspnet-minimal-ioxide/ .
COPY data/static/ wwwroot/static/
RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:11.0-preview
WORKDIR /app
COPY --from=build /app/out .

# HTTP/1.1 only: plaintext (8080) + HTTP/1.1-over-TLS via kTLS (8081). kTLS needs the host 'tls'
# kernel module. h2c, HTTP/2-over-TLS, and HTTP/3 are intentionally omitted.
EXPOSE 8080 8081

ENTRYPOINT ["dotnet", "aspnet-minimal-ioxide.dll"]
