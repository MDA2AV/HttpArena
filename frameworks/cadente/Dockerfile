FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY cadente.csproj ./
RUN dotnet restore -r linux-x64

COPY . .
RUN dotnet publish -c Release -r linux-x64 --self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime-deps:10.0
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080
ENTRYPOINT ["./cadente"]
