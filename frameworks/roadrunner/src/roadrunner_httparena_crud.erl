-module(roadrunner_httparena_crud).

-export([init/0]).
-export([list/1, get/1, create/1, update/1]).

-define(CACHE, httparena_crud_cache).

-spec init() -> ok.
init() ->
    case ets:info(?CACHE, name) of
        undefined ->
            ets:new(?CACHE, [
                public,
                named_table,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ ->
            ok
    end,
    ok.

list(Req) ->
    Qs = roadrunner_req:parse_qs(Req),
    Cat = qs_bin(~"category", Qs, ~"electronics"),
    Page = max(1, qs_int(~"page", Qs, 1)),
    Limit = clamp(qs_int(~"limit", Qs, 10), 1, 50),
    Offset = (Page - 1) * Limit,
    ListSql = ~"""
    SELECT id, name, category, price, quantity, active, tags,
           rating_score, rating_count
      FROM items
     WHERE category = $1
     ORDER BY id
     LIMIT $2 OFFSET $3
    """,
    {Items, Total} =
        case roadrunner_httparena_db:query(ListSql, [Cat, Limit, Offset]) of
            {ok, _, Rows} ->
                {[roadrunner_httparena_items:row_to_json(R) || R <- Rows], length(Rows)};
            _ ->
                {[], 0}
        end,
    Body = #{~"items" => Items, ~"total" => Total, ~"page" => Page},
    {roadrunner_resp:json(200, Body), Req}.

get(Req) ->
    Id = id_from_path(Req),
    case ets:lookup(?CACHE, Id) of
        [{Id, Body}] ->
            Resp = json_body(Body),
            {roadrunner_resp:add_header(Resp, ~"x-cache", ~"HIT"), Req};
        [] ->
            case roadrunner_httparena_db:query(read_sql(), [Id]) of
                {ok, _, [Row]} ->
                    Item = roadrunner_httparena_items:row_to_json(Row),
                    Body = iolist_to_binary(json:encode(Item)),
                    ets:insert(?CACHE, {Id, Body}),
                    Resp = json_body(Body),
                    {roadrunner_resp:add_header(Resp, ~"x-cache", ~"MISS"), Req};
                _ ->
                    {roadrunner_resp:not_found(), Req}
            end
    end.

%% Cache stores the already-encoded JSON body, so a cache hit ships the
%% bytes verbatim instead of re-encoding the item map every request.
json_body(Body) ->
    roadrunner_resp:with_length(200, ~"application/json", Body).

create(Req) ->
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    Input = json:decode(Body),
    Id = maps:get(~"id", Input),
    Sql = ~"""
    INSERT INTO items (id, name, category, price, quantity,
                       active, tags, rating_score, rating_count)
    VALUES ($1, $2, $3, $4, $5, true, '[]'::jsonb, 0, 0)
    ON CONFLICT (id) DO UPDATE
       SET name = EXCLUDED.name,
           category = EXCLUDED.category,
           price = EXCLUDED.price,
           quantity = EXCLUDED.quantity
    """,
    case roadrunner_httparena_db:query(Sql, [
        Id,
        maps:get(~"name", Input),
        maps:get(~"category", Input),
        maps:get(~"price", Input),
        maps:get(~"quantity", Input)
    ]) of
        {ok, 1} ->
            ets:delete(?CACHE, Id),
            {roadrunner_resp:status(201), Req2};
        _ ->
            {roadrunner_resp:internal_error(), Req2}
    end.

update(Req) ->
    Id = id_from_path(Req),
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    Input = json:decode(Body),
    Sql = ~"""
    UPDATE items
       SET name = $2, category = $3, price = $4, quantity = $5
     WHERE id = $1
    """,
    case roadrunner_httparena_db:query(Sql, [
        Id,
        maps:get(~"name", Input),
        maps:get(~"category", Input),
        maps:get(~"price", Input),
        maps:get(~"quantity", Input)
    ]) of
        {ok, 1} ->
            ets:delete(?CACHE, Id),
            {roadrunner_resp:status(200), Req2};
        {ok, 0} ->
            {roadrunner_resp:not_found(), Req2};
        _ ->
            {roadrunner_resp:internal_error(), Req2}
    end.

read_sql() ->
    ~"""
    SELECT id, name, category, price, quantity, active, tags,
           rating_score, rating_count
      FROM items
     WHERE id = $1
    """.

id_from_path(Req) ->
    binary_to_integer(maps:get(~"id", roadrunner_req:bindings(Req))).

qs_int(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {Key, V} when is_binary(V) ->
            case string:to_integer(V) of
                {N, _} when is_integer(N) -> N;
                _ -> Default
            end;
        _ ->
            Default
    end.

qs_bin(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {Key, V} when is_binary(V) -> V;
        _ -> Default
    end.

clamp(N, Lo, _Hi) when N < Lo -> Lo;
clamp(N, _Lo, Hi) when N > Hi -> Hi;
clamp(N, _Lo, _Hi) -> N.
