FROM mcr.microsoft.com/dotnet/sdk:11.0.100-preview.7 AS build
WORKDIR /source

COPY genhttp.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:11.0.0-preview.7
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080 8081 8443
ENTRYPOINT ["dotnet", "genhttp.dll"]
