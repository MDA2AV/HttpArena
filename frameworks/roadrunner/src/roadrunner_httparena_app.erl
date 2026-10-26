-module(roadrunner_httparena_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, SupPid} = roadrunner_httparena_sup:start_link(),
    ok = roadrunner_httparena_dataset:load(),
    ok = roadrunner_httparena_cache:new(),
    _ = roadrunner_httparena_db:start_pool(),
    Routes = roadrunner_httparena_handler:routes(),
    HttpPort = application:get_env(roadrunner_httparena, http_port, 8080),
    {ok, _} = roadrunner:start_listener(httparena_http, #{
        port => HttpPort,
        routes => Routes,
        %% High-concurrency profiles offer thousands of connections (async
        %% holds 32768 at once); size the cap above the largest profile plus
        %% churn headroom so the listener keeps every offered connection live
        %% instead of capping and forcing the load generator into a
        %% reconnect storm.
        max_clients => 65536,
        %% The async profile opens 32K connections at once; deepen the
        %% kernel accept queue past the storm size (the kernel clamps
        %% this to `net.core.somaxconn`), like the h2c listener below.
        socket_backlog => 32768,
        %% WebSocket sessions inherit the listener's 64 KB socket buffer,
        %% held live per socket; the echo profiles exchange small text
        %% frames, so shrink it per roadrunner's ws.recv_buffer production
        %% guidance for small-message, high-concurrency deployments.
        ws => #{recv_buffer => 4096}
    }),
    H2cPort = application:get_env(roadrunner_httparena, h2c_port, 8082),
    {ok, _} = roadrunner:start_listener(httparena_h2c, #{
        port => H2cPort,
        routes => Routes,
        %% h2 multiplexes many streams per connection: the connection cap
        %% covers the largest h2c profile (4096 connections) with headroom,
        %% and the advertised `max_concurrent_streams` bounds per-stream
        %% state the way h2 servers conventionally do — clients window
        %% themselves to the advertised limit (RFC 9113 §5.1.2), so unlike
        %% a server-side refusal cap this sheds no requests (roadrunner's
        %% resource-limits guide recommends sizing the advertised limits
        %% over the refusal cap). This listener serves the compressed
        %% `/json` route, where every in-flight stream holds a deflate
        %% context (~200 KB measured), so the window is sized for
        %% worst-case handler memory: 4 × 4096 connections ≈ 16K live
        %% streams ≈ 3.5 GB, the regime measured stable — 16 × put it
        %% near 14 GB and the profile timed out entirely.
        max_clients => 8192,
        %% The connection-heavy profiles open thousands of connections at
        %% once while accepted ones already run compressed handlers, so
        %% deepen the kernel accept queue past the storm size (default
        %% 1024 overflowed, black-holing connections).
        socket_backlog => 8192,
        %% h2c prior-knowledge: `[http2]` on a plain-TCP listener
        %% serves h2 directly (client sends the h2 preface, no
        %% `Upgrade: h2c` negotiation).
        protocols => [{http2, #{max_concurrent_streams => 4}}]
    }),
    case tls_opts() of
        {ok, TlsOpts} ->
            TlsPort = application:get_env(roadrunner_httparena, tls_port, 8081),
            {ok, _} = roadrunner:start_listener(httparena_tls, #{
                port => TlsPort,
                routes => Routes,
                max_clients => 65536,
                tls => TlsOpts
            }),
            H2Port = application:get_env(roadrunner_httparena, h2_port, 8443),
            {ok, _} = roadrunner:start_listener(httparena_h2, #{
                port => H2Port,
                routes => Routes,
                tls => TlsOpts,
                %% Same connection/stream bounds as the h2c listener above.
                max_clients => 8192,
                %% Listener derives `alpn_preferred_protocols` from
                %% this list — `h2` preferred, fall back to `http/1.1`.
                %% `http3` co-serves over QUIC on UDP 8443 (same port
                %% number) and auto-advertises `Alt-Svc: h3=":8443"` on
                %% the h1/h2 responses. Serves baseline-h3 / static-h3.
                protocols => [{http2, #{max_concurrent_streams => 16}}, http1, http3]
            });
        skip ->
            ok
    end,
    {ok, SupPid}.

stop(_State) ->
    ok.

tls_opts() ->
    Cert = env_path("TLS_CERT_PATH", tls_cert, "/certs/server.crt"),
    Key = env_path("TLS_KEY_PATH", tls_key, "/certs/server.key"),
    case filelib:is_regular(Cert) andalso filelib:is_regular(Key) of
        true -> {ok, [{certfile, Cert}, {keyfile, Key}]};
        false -> skip
    end.

env_path(EnvVar, AppKey, Default) ->
    case os:getenv(EnvVar) of
        false -> application:get_env(roadrunner_httparena, AppKey, Default);
        V -> V
    end.
