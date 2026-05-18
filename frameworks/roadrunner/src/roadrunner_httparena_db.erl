-module(roadrunner_httparena_db).

-export([start_pool/0, query/2]).

-define(POOL, httparena_pg).

-spec start_pool() -> ok | disabled.
start_pool() ->
    case os:getenv("DATABASE_URL") of
        false ->
            disabled;
        Url ->
            ConnMap = parse_url(Url),
            Size = pool_size(),
            PoolConfig = [
                {name, ?POOL},
                {init_count, Size},
                {max_count, Size},
                {start_mfa, {epgsql, connect, [ConnMap]}}
            ],
            {ok, _Pid} = pooler:new_pool(PoolConfig),
            ok
    end.

-spec query(iodata(), [term()]) ->
    {ok, list(), list()} | {ok, non_neg_integer()} | {error, term()}.
query(Sql, Params) ->
    case pooler:take_member(?POOL) of
        Conn when is_pid(Conn) ->
            try
                epgsql:equery(Conn, Sql, Params)
            after
                pooler:return_member(?POOL, Conn, ok)
            end;
        error_no_members ->
            {error, no_members}
    end.

parse_url(Url) ->
    Parsed = uri_string:parse(Url),
    {User, Pass} = split_userinfo(maps:get(userinfo, Parsed, "")),
    Database = strip_slash(maps:get(path, Parsed, "/")),
    #{
        host => maps:get(host, Parsed, "localhost"),
        port => maps:get(port, Parsed, 5432),
        username => User,
        password => Pass,
        database => Database
    }.

split_userinfo("") ->
    {"", ""};
split_userinfo(UserInfo) ->
    case string:split(UserInfo, ":") of
        [U, P] -> {U, P};
        [U] -> {U, ""}
    end.

strip_slash("/" ++ Rest) -> Rest;
strip_slash(Other) -> Other.

pool_size() ->
    case os:getenv("DATABASE_MAX_CONN") of
        false ->
            32;
        S ->
            case string:to_integer(S) of
                {N, _} when is_integer(N), N > 0 -> min(N, 256);
                _ -> 32
            end
    end.
