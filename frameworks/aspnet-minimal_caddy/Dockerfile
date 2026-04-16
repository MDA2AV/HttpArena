FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app

# Copy project file and shared source from aspnet-minimal. We reuse the
# same Handlers/AppData/Models as aspnet-minimal_nginx — the only thing
# specific to this entry is the Caddy proxy config.
COPY frameworks/aspnet-minimal_caddy/aspnet-minimal_caddy.csproj .
COPY frameworks/aspnet-minimal_caddy/Program.cs .
COPY frameworks/aspnet-minimal/Handlers.cs .
COPY frameworks/aspnet-minimal/AppData.cs .
COPY frameworks/aspnet-minimal/Models.cs .

RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080

ENTRYPOINT ["dotnet", "aspnet-minimal_caddy.dll"]
