FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app

# Copy project file and shared source from aspnet-minimal
COPY frameworks/aspnet-minimal_nginx/aspnet-minimal_nginx.csproj .
COPY frameworks/aspnet-minimal_nginx/Program.cs .
COPY frameworks/aspnet-minimal/Handlers.cs .
COPY frameworks/aspnet-minimal/AppData.cs .
COPY frameworks/aspnet-minimal/Models.cs .

RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:10.0

# StackExchange.Redis' TLS/auth layer tries to load libgssapi_krb5.so.2 at
# connection time even though we don't use Kerberos — the library isn't
# installed in aspnet:10.0 by default. Without it, Redis operations fail
# silently (the connection opens but SET/GET return errors the client
# swallows). Install the Debian package to unblock the Redis path.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgssapi-krb5-2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080

ENTRYPOINT ["dotnet", "aspnet-minimal_nginx.dll"]
