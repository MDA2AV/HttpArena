FROM mcr.microsoft.com/dotnet/sdk:11.0.100-preview.5 AS build
WORKDIR /src

# Monoxide - the ioxide-native HTTP/1.1 framework. Cloned to /src/monoxide, where
# monoxide-arena.csproj's $(MonoxideSrc) project reference resolves. Monoxide pulls
# ioxide + Glyph11 + ioxide.file from nuget.org transitively. This entry targets
# net11.0; the SDK provides the .NET 11 framework (preview).
RUN git clone --depth 1 https://github.com/MDA2AV/Monoxide.git monoxide

WORKDIR /src/app
COPY . .
RUN dotnet publish monoxide-arena.csproj -c Release --no-self-contained -o /app

FROM mcr.microsoft.com/dotnet/runtime:11.0.0-preview.5
WORKDIR /app
COPY --from=build /app .

EXPOSE 8080 8081
ENTRYPOINT ["dotnet", "monoxide-arena.dll"]
