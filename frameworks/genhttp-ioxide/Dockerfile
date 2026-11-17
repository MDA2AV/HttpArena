FROM mcr.microsoft.com/dotnet/sdk:11.0 AS build

# GenHTTP built from source: the branch of Kaliumhexacyanoferrat/GenHTTP#953
# (update-ioxide-0.20.396) rather than the 11.3.0 release. Pinned to one commit,
# because a build on cached layers would otherwise keep whichever it cloned first.
ARG GENHTTP_COMMIT=28b0cd107bb36321408a3a1f892f3bb45225e9d7
RUN git init -q /genhttp \
 && git -C /genhttp fetch -q --depth 1 https://github.com/Kaliumhexacyanoferrat/GenHTTP.git "$GENHTTP_COMMIT" \
 && git -C /genhttp checkout -q FETCH_HEAD

WORKDIR /src/app

COPY genhttp.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish genhttp.csproj -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:11.0
WORKDIR /app
COPY --from=build /app .

# 8080 h1, 8081 h1+TLS, 8082 h2c, 8443 h2 over TCP and h3 over QUIC (UDP)
EXPOSE 8080 8081 8082 8443 8443/udp
ENTRYPOINT ["dotnet", "genhttp.dll"]
