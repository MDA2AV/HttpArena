FROM mcr.microsoft.com/dotnet/sdk:11.0 AS build

# GenHTTP from its ioxide-update branch (PR #953) instead of NuGet, fetched by commit so a later
# push to the branch can't change what this measures.
ARG GENHTTP_REPO=https://github.com/Kaliumhexacyanoferrat/GenHTTP.git
ARG GENHTTP_REF=update-ioxide-0.20.396
ARG GENHTTP_COMMIT=a5d6314e2e1ee79f6657c98dd2081a1e2116b98f

WORKDIR /src/GenHTTP
RUN echo "Building GenHTTP ${GENHTTP_REF} at ${GENHTTP_COMMIT}" && \
    git init -q && \
    git remote add origin "${GENHTTP_REPO}" && \
    git fetch -q --depth 1 origin "${GENHTTP_COMMIT}" && \
    git checkout -q FETCH_HEAD

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
