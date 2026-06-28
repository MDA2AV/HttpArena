-module(roadrunner_httparena_db).

-export([start_pool/0, query/2]).

%% Connections live in a persistent_term tuple, addressed lock-free per
%% request (no central checkout broker, so nothing serializes the pool).
-define(CONNS_KEY, {?MODULE, conns}).

%% Every SQL the adapter runs, keyed by an atom name. Each statement is
%% parsed once per connection at connect time (named after its key), so the
%% hot path runs `epgsql:prepared_query/3` against a cached `#statement{}`
%% record instead of re-parsing on every request.
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

-spec start_pool() -> ok | disabled.
start_pool() ->
    case os:getenv("DATABASE_URL") of
        false ->
            disabled;
        Url ->
            ConnMap = parse_url(Url),
            Size = pool_size(),
            Conns = list_to_tuple([connect(ConnMap) || _ <- lists:seq(1, Size)]),
            persistent_term:put(?CONNS_KEY, Conns),
            ok
    end.

%% Open a connection and parse every statement on it (the prepared
%% statement must exist on each backend connection). The resulting
%% `#statement{}` metadata is connection-independent, so we cache one per
%% name in `persistent_term`; concurrent connects racing to put the same
%% value is harmless.
-spec connect(epgsql:connect_opts()) -> epgsql:connection().
connect(ConnMap) ->
    {ok, Conn} = epgsql:connect(ConnMap),
    ok = maps:foreach(
        fun(Name, Sql) -> prepare(Conn, Name, Sql) end,
        statements()
    ),
    Conn.

prepare(Conn, Name, Sql) ->
    {ok, Stmt} = epgsql:parse(Conn, atom_to_list(Name), Sql, []),
    Key = {?MODULE, stmt, Name},
    case persistent_term:get(Key, undefined) of
        undefined -> persistent_term:put(Key, Stmt);
        _ -> ok
    end.

%% Pick a connection at random and run the prepared statement on it
%% directly. epgsql serializes commands per connection (its gen_server
%% mailbox), so concurrent callers queue on the chosen connection instead
%% of funneling through one checkout broker — no broker bottleneck and no
%% `no_members` refusals under high concurrency.
-spec query(atom(), [term()]) ->
    {ok, list(), list()} | {ok, non_neg_integer()} | {error, term()}.
query(Name, Params) ->
    Conns = persistent_term:get(?CONNS_KEY),
    Conn = element(rand:uniform(tuple_size(Conns)), Conns),
    epgsql:prepared_query(Conn, persistent_term:get({?MODULE, stmt, Name}), Params).

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
