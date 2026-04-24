FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY genhttp.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080 8081 8443
ENTRYPOINT ["dotnet", "genhttp.dll"]
