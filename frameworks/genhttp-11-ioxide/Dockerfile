FROM mcr.microsoft.com/dotnet/sdk:11.0.100-preview.5 AS build
WORKDIR /src

# GenHTTP with the ioxide io_uring engine (PR #860). Cloned to /src/genhttp,
# which is where genhttp.csproj's $(GenHttpSrc) project references resolve.
# This entry targets net11.0; the cloned ioxide-engine branch must too. The
# :11.0.100-preview.5 SDK provides the .NET 11 framework plus Roslyn 5.3+ for
# GenHTTP's MemoryView source generator.
RUN git clone --depth 1 --branch ioxide-engine https://github.com/Kaliumhexacyanoferrat/GenHTTP.git genhttp

WORKDIR /src/app
COPY . .
RUN dotnet publish genhttp.csproj -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:11.0.0-preview.5
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080 8081
ENTRYPOINT ["dotnet", "genhttp.dll"]
