FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# GenHTTP with the ioxide io_uring engine (PR #860). Cloned to /src/genhttp,
# which is where genhttp.csproj's $(GenHttpSrc) project references resolve.
# Needs an SDK with Roslyn 5.3+ for GenHTTP's MemoryView source generator;
# the :10.0 tag provides it.
RUN git clone --depth 1 --branch ioxide-engine https://github.com/Kaliumhexacyanoferrat/GenHTTP.git genhttp

WORKDIR /src/app
COPY . .
RUN dotnet publish genhttp.csproj -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080
ENTRYPOINT ["dotnet", "genhttp.dll"]
