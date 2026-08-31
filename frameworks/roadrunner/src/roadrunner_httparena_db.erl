-module(roadrunner_httparena_db).

-behaviour(ecpool_worker).

-export([start_pool/0, connect/1, query/2]).

%% `connect/1` is the ecpool_worker callback, invoked by ecpool via the
%% `Mod:connect/1` MFA when it opens (or reopens) a pooled connection, not
%% by a static call, so xref cannot see the reference.
-ignore_xref([{connect, 1}]).

-define(POOL, httparena_pg).

%% Every SQL the adapter runs, keyed by an atom name. Each statement is
%% parsed once per pooled connection at connect time (named after its key),
%% so the hot path runs `epgsql:prepared_query/3` against a cached
%% `#statement{}` record instead of re-parsing on every request.
statements() ->
    #{
        read => ~"""
        SELECT id, name, category, price, quantity, active, tags,
               rating_score, rating_count
          FROM items
         WHERE id = $1
        """,
        list => ~"""
        SELECT id, name, category, price, quantity, active, tags,
               rating_score, rating_count
          FROM items
         WHERE category = $1
         ORDER BY id
         LIMIT $2 OFFSET $3
        """,
        count => ~"SELECT COUNT(*) FROM items WHERE category = $1",
        create => ~"""
        INSERT INTO items (id, name, category, price, quantity,
                           active, tags, rating_score, rating_count)
        VALUES ($1, $2, $3, $4, $5, true, '[]'::jsonb, 0, 0)
        ON CONFLICT (id) DO UPDATE
           SET name = EXCLUDED.name,
               category = EXCLUDED.category,
               price = EXCLUDED.price,
               quantity = EXCLUDED.quantity
        """,
        update => ~"""
        UPDATE items
           SET name = $2, category = $3, price = $4, quantity = $5
         WHERE id = $1
        """,
        async_db => ~"""
        SELECT id, name, category, price, quantity, active, tags,
               rating_score, rating_count
          FROM items
         WHERE price BETWEEN $1 AND $2 LIMIT $3
        """,
        fortunes => ~"SELECT id, message FROM fortune"
    }.

%% Start an ecpool pool of `pool_size()` connections. ecpool routes each
%% request to a worker via `gproc_pool` (an ETS lookup, no central checkout
%% broker), so concurrent callers spread across connections instead of
%% serializing through one coordinator. `auto_reconnect` makes a worker
%% reopen (and re-prepare) its connection if the backend drops it.
-spec start_pool() -> ok | disabled.
start_pool() ->
    case os:getenv("DATABASE_URL") of
        false ->
            disabled;
        Url ->
            ConnMap = parse_url(Url),
            Opts = [
                {pool_size, pool_size()},
                {pool_type, random},
                {auto_reconnect, 2},
                {conn_map, ConnMap}
            ],
            {ok, _} = ecpool:start_sup_pool(?POOL, ?MODULE, Opts),
            ok
    end.

%% ecpool_worker callback: open a connection and parse every statement on it
%% (the prepared statement must exist on each backend connection). The
%% resulting `#statement{}` metadata is connection-independent, so we cache
%% one per name in `persistent_term`; connections racing to put the same
%% value (including after a reconnect) is harmless.
-spec connect([term()]) -> {ok, epgsql:connection()}.
connect(Opts) ->
    {conn_map, ConnMap} = lists:keyfind(conn_map, 1, Opts),
    {ok, Conn} = epgsql:connect(ConnMap),
    ok = maps:foreach(
        fun(Name, Sql) -> prepare(Conn, Name, Sql) end,
        statements()
    ),
    {ok, Conn}.

prepare(Conn, Name, Sql) ->
    {ok, Stmt} = epgsql:parse(Conn, atom_to_list(Name), Sql, []),
    Key = {?MODULE, stmt, Name},
    case persistent_term:get(Key, undefined) of
        undefined -> persistent_term:put(Key, Stmt);
        _ -> ok
    end.

%% Run the prepared statement on a pool-picked connection. ecpool hands the
%% callback the connection chosen for this request; epgsql serializes
%% commands per connection through its own mailbox, so callers queue on the
%% chosen connection, never on a shared broker. A worker mid-reconnect
%% yields `{error, disconnected}`, which the handlers map to a 5xx.
-spec query(atom(), [term()]) ->
    {ok, list(), list()} | {ok, non_neg_integer()} | {error, term()}.
query(Name, Params) ->
    Stmt = persistent_term:get({?MODULE, stmt, Name}),
    ecpool:with_client(?POOL, fun(Conn) ->
        epgsql:prepared_query(Conn, Stmt, Params)
    end).

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
