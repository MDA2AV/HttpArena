FROM ubuntu:26.04 AS build

RUN apt update
RUN apt install -y dotnet-sdk-10.0

COPY web_framework_benchmark/ .

RUN dotnet publish -c Release -p:PublishDir=/app

FROM ubuntu:26.04

ENV WEB_FRAMEWORK_CSHARP_API_PATH=/app/WebFrameworkCSharpAPI.dll

RUN apt update
RUN apt install -y dotnet-runtime-10.0

RUN LD_LIBRARY_PATH=$(find / -name libhostfxr.so) && echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >> /etc/environment

COPY --from=build /app/ /app

WORKDIR /app

RUN ln -s $(find / -name libhostfxr.so)

CMD ["LD_LIBRARY_PATH=/app", "dotnet", "./Server.dll"]
