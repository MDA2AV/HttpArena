# Stage 1: Build the custom .NET runtime with io_uring socket engine
FROM mcr.microsoft.com/dotnet/sdk:11.0-preview AS runtime-build
RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake clang lld llvm python3 ninja-build \
    libicu-dev libssl-dev libkrb5-dev zlib1g-dev \
    liblttng-ust-dev libunwind-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /runtime
COPY patch-iouring.py /tmp/patch-iouring.py
RUN git clone --depth 1 --branch io_uring https://github.com/benaadams/runtime.git . \
    && python3 /tmp/patch-iouring.py \
    && ./build.sh -subset clr+libs -c Release -bl \
    && echo "=== Build artifacts ===" \
    && ls -la /runtime/artifacts/bin/runtime/ \
    && echo "=== System.Net.Sockets.dll location ===" \
    && find /runtime/artifacts -name "System.Net.Sockets.dll" -type f 2>/dev/null

# Stage 2: Build the app using the official SDK
FROM mcr.microsoft.com/dotnet/sdk:11.0-preview AS app-build
WORKDIR /app
COPY *.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o out

# Stage 3: Final image — patch the runtime with io_uring binaries
FROM mcr.microsoft.com/dotnet/aspnet:11.0-preview

# Install libmsquic for HTTP/3
ADD https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb /packages-microsoft-prod.deb
RUN dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Overlay custom runtime libraries (io_uring socket engine)
COPY --from=runtime-build /runtime/artifacts/bin/runtime/net11.0-linux-Release-x64/ /tmp/iouring-runtime/
RUN cp -f /tmp/iouring-runtime/* /usr/share/dotnet/shared/Microsoft.NETCore.App/11.0.0-preview.*/ \
    && rm -rf /tmp/iouring-runtime \
    && echo "=== Overlay applied to ===" && ls -d /usr/share/dotnet/shared/Microsoft.NETCore.App/11.0.0-preview.*

WORKDIR /app
COPY --from=app-build /app/out .
EXPOSE 8080 8443/tcp 8443/udp

# Enable io_uring socket engine with SQPOLL (kernel-side polling)
ENV DOTNET_SYSTEM_NET_SOCKETS_IO_URING=1
ENV DOTNET_SYSTEM_NET_SOCKETS_IO_URING_SQPOLL=1

ENTRYPOINT ["dotnet", "aspnet-minimal-iouring.dll"]
