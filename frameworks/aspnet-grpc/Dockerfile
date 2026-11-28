FROM mcr.microsoft.com/dotnet/sdk:11.0 AS build
WORKDIR /app
COPY . .
RUN dotnet publish -c Release -o out

FROM mcr.microsoft.com/dotnet/aspnet:11.0
WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080 8443
ENTRYPOINT ["dotnet", "aspnet-grpc.dll"]
