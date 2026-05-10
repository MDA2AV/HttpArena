FROM ubuntu:26.04 AS build

RUN apt update
RUN apt install -y dotnet-sdk-10.0

COPY web_framework_benchmark/ .

RUN dotnet publish -c Release -p:PublishDir=/app

FROM ubuntu:26.04

RUN apt update
RUN apt install -y dotnet-runtime-10.0

RUN LD_LIBRARY_PATH=$(find / -name libhostfxr.so) && echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >> /etc/environment

COPY --from=build /app/ /app

WORKDIR /app

CMD ["dotnet", "./Server.dll"]
