FROM dart:3.14 AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY bin bin
COPY lib lib
RUN dart build cli --target bin/server.dart --output /app/build

# The dart image's /runtime holds the few libs an AOT binary needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/build/bundle /app
COPY resources /app/resources
EXPOSE 8080 8082
WORKDIR /app
ENTRYPOINT ["/app/bin/server"]
