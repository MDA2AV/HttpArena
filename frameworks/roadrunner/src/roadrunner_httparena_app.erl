-module(roadrunner_httparena_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, SupPid} = roadrunner_httparena_sup:start_link(),
    ok = roadrunner_httparena_dataset:load(),
    _ = roadrunner_httparena_db:start_pool(),
    ok = roadrunner_httparena_crud:init(),
    Routes = roadrunner_httparena_handler:routes(),
    HttpPort = application:get_env(roadrunner_httparena, http_port, 8080),
    {ok, _} = roadrunner:start_listener(httparena_http, #{
        port => HttpPort,
        routes => Routes,
        %% High-concurrency profiles offer thousands of connections (async
        %% holds 32768 at once); size the cap above the largest profile plus
        %% churn headroom so the listener keeps every offered connection live
        %% instead of capping and forcing the load generator into a
        %% reconnect storm, and widen the acceptor pool for the
        %% connection-churn profiles.
        max_clients => 65536,
        num_acceptors => 100,
        %% WebSocket sessions inherit the listener's 64 KB socket buffer,
        %% held live per socket; the echo profiles exchange small text
        %% frames, so shrink it per roadrunner's ws.recv_buffer production
        %% guidance for small-message, high-concurrency deployments.
        ws => #{recv_buffer => 4096},
        %% 25 MB headroom for the 8gbit profile (validator goes up to 20 MB).
        max_content_length => 26214400,
        %% Manual body buffering: handlers read the body themselves via
        %% `roadrunner_req:read_body[_chunked]/1`. Lets the echo handler
        %% stream chunks instead of buffering the entire 20 MB body in
        %% the conn process before dispatch. Auto-mode handlers
        %% (`baseline11` POST) still work transparently via `read_body/1`.
        body_buffering => manual
    }),
    H2cPort = application:get_env(roadrunner_httparena, h2c_port, 8082),
    {ok, _} = roadrunner:start_listener(httparena_h2c, #{
        port => H2cPort,
        routes => Routes,
        max_content_length => 26214400,
        %% h2 multiplexes many streams per connection: the connection cap
        %% covers the largest h2c profile (4096 connections) with headroom,
        %% and the advertised `max_concurrent_streams` bounds per-stream
        %% state (e.g. `/json` gzip contexts, otherwise measured in the
        %% multi-GiB range here) the way h2 servers conventionally do —
        %% clients window themselves to the advertised limit (RFC 9113
        %% §5.1.2), so unlike a server-side refusal cap this sheds no
        %% requests. 16 × the connection cap keeps the worst-case live
        %% streams well inside the BEAM process limit.
        max_clients => 8192,
        %% h2c prior-knowledge: `[http2]` on a plain-TCP listener
        %% serves h2 directly (client sends the h2 preface, no
        %% `Upgrade: h2c` negotiation).
        protocols => [{http2, #{max_concurrent_streams => 16}}],
        body_buffering => manual
    }),
    case tls_opts() of
        {ok, TlsOpts} ->
            TlsPort = application:get_env(roadrunner_httparena, tls_port, 8081),
            {ok, _} = roadrunner:start_listener(httparena_tls, #{
                port => TlsPort,
                routes => Routes,
                max_clients => 65536,
                num_acceptors => 100,
                max_content_length => 26214400,
                tls => TlsOpts,
                body_buffering => manual
            }),
            H2Port = application:get_env(roadrunner_httparena, h2_port, 8443),
            {ok, _} = roadrunner:start_listener(httparena_h2, #{
                port => H2Port,
                routes => Routes,
                max_content_length => 26214400,
                tls => TlsOpts,
                %% Same connection/stream bounds as the h2c listener above.
                max_clients => 8192,
                %% Listener derives `alpn_preferred_protocols` from
                %% this list — `h2` preferred, fall back to `http/1.1`.
                %% `http3` co-serves over QUIC on UDP 8443 (same port
                %% number) and auto-advertises `Alt-Svc: h3=":8443"` on
                %% the h1/h2 responses. Serves baseline-h3 / static-h3.
                protocols => [{http2, #{max_concurrent_streams => 16}}, http1, http3],
                body_buffering => manual
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
