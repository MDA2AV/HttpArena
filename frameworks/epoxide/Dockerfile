# Pinned rather than floating, as on edixoi: a preview tag moving under the entry has changed its
# baseline number before, which is not something a tag should be able to do silently. SDK and
# runtime version their tags differently: 11.0.1xx vs 11.0.0.
ARG DOTNET_SDK_TAG=11.0.100-preview.7
ARG DOTNET_RUNTIME_TAG=11.0.0-preview.7

# epoxide is not on NuGet yet: its source at a pinned commit of the ioxide repo, with the BoringSSL
# it links (the one ioxide bundles). To build a tree that is not pushed, replace the epoxide-src
# stage with a directory holding the same three paths: --build-context epoxide-src=<dir>
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS epoxide-fetch
ARG EPOXIDE_COMMIT=d7309d5647ecacbb2235561e5a936397d32774aa
WORKDIR /ioxide
RUN git init -q \
 && git remote add origin https://github.com/MDA2AV/ioxide.git \
 && git fetch -q --depth 1 origin "${EPOXIDE_COMMIT}" \
 && git checkout -q FETCH_HEAD -- src/Directory.Build.props src/epoxide \
        src/ioxide/runtimes/linux-x64/native/libioxide_boringssl.so

FROM scratch AS epoxide-src
COPY --from=epoxide-fetch /ioxide/src /src

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS build
COPY --from=epoxide-src /src /ioxide/src
WORKDIR /source
COPY epoxide-arena.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release --no-self-contained -o /app/out

# epoxide drives epoll through direct libc syscalls: nothing here needs io_uring, and nothing
# needs the seccomp opening the io_uring entries do.
ARG DOTNET_RUNTIME_TAG
FROM mcr.microsoft.com/dotnet/runtime:${DOTNET_RUNTIME_TAG}
WORKDIR /app
COPY --from=build /app/out ./
EXPOSE 8080
ENTRYPOINT ["dotnet", "epoxide-arena.dll"]
