FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app
COPY frameworks/servicestack/ .
COPY data/static/ wwwroot/static/
RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:10.0

WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080

ENTRYPOINT ["dotnet", "servicestack-bench.dll"]