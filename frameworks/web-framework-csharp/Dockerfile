FROM ubuntu:26.04 AS build

RUN apt update
RUN apt install -y dotnet-sdk-10.0

COPY web_framework_benchmark/ .

RUN dotnet publish -c Release -p:PublishDir=/app

FROM ubuntu:26.04

ENV WEB_FRAMEWORK_CSHARP_API_PATH=/app/WebFrameworkCSharpAPI.dll
ENV LD_LIBRARY_PATH=/app:/app/runtimes/linux-x64/native

RUN apt update
RUN apt install -y dotnet-runtime-10.0

COPY --from=build /app/ /app

WORKDIR /app

RUN ln -s $(find / -name libhostfxr.so)

CMD ["dotnet", "./Server.dll"]
