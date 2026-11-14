# Http11Probe, pointed at HttpArena's /spec route: the H/1.1 compliance suite.
#
# The probe sends its requests to "/" and reads request headers back from
# "/echo". HttpArena entries serve neither, so every request line is moved onto
# the /spec contract (site/content/docs/test-profiles/compliance/): "/" becomes
# /spec and the header echo becomes /spec/headers. The request bodies, framing
# and everything the verdicts look at stay exactly as upstream wrote them.
#
# Built from one pinned commit (PROBE_COMMIT, set by scripts/spec.sh), so the
# rewrite always edits the code it was checked against, and the build fails if
# any request line on "/" survives it -- a new test upstream that the rewrite
# does not cover cannot quietly probe a route no entry has.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

ARG PROBE_REPO=https://github.com/MDA2AV/Http11Probe.git
ARG PROBE_COMMIT
RUN test -n "$PROBE_COMMIT" || { echo "PROBE_COMMIT is required"; exit 1; }

WORKDIR /src
RUN git init -q . \
    && git remote add origin "$PROBE_REPO" \
    && git fetch -q --depth 1 origin "$PROBE_COMMIT" \
    && git checkout -q FETCH_HEAD

WORKDIR /src/src/Http11Probe/TestCases/Suites
RUN sed -i -E \
        -e 's#(GET|POST|HEAD|OPTIONS|PUT|DELETE|PATCH|TRACE) / HTTP#\1 /spec HTTP#g' \
        -e 's#GET  / HTTP#GET  /spec HTTP#g' \
        -e 's#get / HTTP#get /spec HTTP#g' \
        -e 's#FOOBAR / HTTP#FOOBAR /spec HTTP#g' \
        -e 's#\{longMethod\} / HTTP#{longMethod} /spec HTTP#g' \
        -e 's#/echo HTTP#/spec/headers HTTP#g' \
        *.cs \
    && if grep -nE '[A-Za-z}]  ?/ HTTP/' *.cs; then \
           echo "request lines above still target / - extend the rewrite"; exit 1; \
       fi

WORKDIR /src
RUN dotnet publish src/Http11Probe.Cli/Http11Probe.Cli.csproj -c Release -o /out --nologo -v quiet

FROM mcr.microsoft.com/dotnet/runtime:10.0
COPY --from=build /out /probe
# Run as whatever user spec.sh passes, writing its report into a mounted dir.
ENV HOME=/tmp DOTNET_CLI_HOME=/tmp DOTNET_NOLOGO=1
ENTRYPOINT ["dotnet", "/probe/Http11Probe.Cli.dll"]
