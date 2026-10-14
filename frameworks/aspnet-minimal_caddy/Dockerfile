FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app

# The project file and Program.cs are this entry's; the handlers, services
# and types are aspnet-minimal's, compiled in as-is. The only thing specific
# to this entry is the Caddy proxy config.
COPY frameworks/aspnet-minimal_caddy/aspnet-minimal_caddy.csproj .
COPY frameworks/aspnet-minimal_caddy/Program.cs .
COPY frameworks/aspnet-minimal/Handlers.cs .
COPY frameworks/aspnet-minimal/Services ./Services
COPY frameworks/aspnet-minimal/Types ./Types

RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080

ENTRYPOINT ["dotnet", "aspnet-minimal_caddy.dll"]
