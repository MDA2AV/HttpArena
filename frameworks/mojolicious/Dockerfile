FROM perl:5.42.0-slim-bookworm AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev make \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY cpanfile .
RUN cpanm --notest --installdeps .

FROM perl:5.42.0-slim-bookworm
COPY --from=build /usr/local/lib/perl5/site_perl /usr/local/lib/perl5/site_perl
WORKDIR /app
COPY app.pl .
ENV MOJO_MODE=production
EXPOSE 8080
CMD ["perl", "app.pl"]
