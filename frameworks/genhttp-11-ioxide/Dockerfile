FROM mcr.microsoft.com/dotnet/sdk:11.0.100-preview.5 AS build
WORKDIR /src/app

# Restore from nuget.org: GenHTTP 11 plus the published ioxide io_uring engine
# (GenHTTP.Engine.Ioxide / GenHTTP.Modules.IoxideFiles) and ioxide.pg / ioxide.tls.
# The :11.0.100-preview.5 SDK provides .NET 11 plus Roslyn 5.3+ for GenHTTP's
# MemoryView source generator.
COPY genhttp.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish genhttp.csproj -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:11.0.0-preview.5
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080 8081
ENTRYPOINT ["dotnet", "genhttp.dll"]
