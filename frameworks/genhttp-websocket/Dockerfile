FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /source

COPY genhttp-websocket.csproj ./
RUN dotnet restore -r linux-musl-x64

COPY . .

RUN dotnet publish -c Release -r linux-musl-x64 --self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080
ENTRYPOINT ["./genhttp-websocket"]
