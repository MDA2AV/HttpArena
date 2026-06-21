FROM mcr.microsoft.com/dotnet/sdk:11.0-preview AS build
WORKDIR /app
COPY frameworks/aspnet-minimal-ioxide/ .
COPY data/static/ wwwroot/static/
RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:11.0-preview
WORKDIR /app
COPY --from=build /app/out .

# Plaintext h1 (8080) + cleartext h2 (8082). TLS (8443/8081) and HTTP/3 are not enabled —
# see the README: HTTP-over-TLS on the ioxide transport is a tracked follow-up.
EXPOSE 8080 8082

ENTRYPOINT ["dotnet", "aspnet-minimal-ioxide.dll"]
