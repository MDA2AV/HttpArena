-module(nhttp_httparena_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(HANDLER, nhttp_httparena_handler).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {Flags, [h1_listener(), h2c_listener() | tls_listeners()]}}.

%% The profiles hold up to 32000 connections and open them in one burst. The
%% nhttp defaults are 1024 connections and a backlog of 1024.
h1_listener() ->
    nhttp:child_spec(httparena_h1, #{
        port => 8080,
        handler => ?HANDLER,
        max_connections => 65536,
        backlog => 32768
    }).

h2c_listener() ->
    nhttp:child_spec(httparena_h2c, #{
        port => 8082,
        handler => ?HANDLER,
        versions => [http2],
        max_connections => 65536,
        backlog => 8192
    }).

tls_listeners() ->
    Cert = env("TLS_CERT_PATH", "/certs/server.crt"),
    Key = env("TLS_KEY_PATH", "/certs/server.key"),
    case filelib:is_regular(Cert) andalso filelib:is_regular(Key) of
        true -> [h1_tls_listener(Cert, Key), tls_listener(Cert, Key)];
        false -> []
    end.

h1_tls_listener(Cert, Key) ->
    nhttp:child_spec(httparena_h1_tls, #{
        port => 8081,
        handler => ?HANDLER,
        versions => [http1_1],
        tls => #{certfile => Cert, keyfile => Key},
        max_connections => 65536,
        backlog => 8192
    }).

tls_listener(Cert, Key) ->
    nhttp:child_spec(httparena_tls, #{
        port => 8443,
        handler => ?HANDLER,
        versions => [http1_1, http2, http3],
        tls => #{certfile => Cert, keyfile => Key},
        quic => quic_opts(),
        max_connections => 65536,
        backlog => 8192
    }).

%% h2load-h3 sends to `localhost`, which resolves to ::1 first on some hosts.
%% QUIC then listens dual-stack, unless the host cannot bind an IPv6 socket.
quic_opts() ->
    case inet:getaddrs("localhost", inet6) of
        {ok, [_ | _]} -> dual_stack(socket:open(inet6, dgram, udp));
        {error, _} -> #{}
    end.

dual_stack({ok, Sock}) ->
    Bound = socket:bind(Sock, #{family => inet6, addr => any, port => 0}),
    ok = socket:close(Sock),
    case Bound of
        ok -> #{ip => {0, 0, 0, 0, 0, 0, 0, 0}, ipv6_v6only => false};
        {error, _} -> #{}
    end;
dual_stack({error, _}) ->
    #{}.

env(Var, Default) ->
    case os:getenv(Var) of
        false -> Default;
        Value -> Value
    end.
