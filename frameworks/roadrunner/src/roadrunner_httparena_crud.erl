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
    Items =
        case roadrunner_httparena_db:query(list, [Cat, Limit, Offset]) of
            {ok, _, Rows} -> [roadrunner_httparena_items:row_to_json(R) || R <- Rows];
            _ -> []
        end,
    Total =
        case roadrunner_httparena_db:query(count, [Cat]) of
            {ok, _, [{N}]} -> N;
            _ -> 0
        end,
    Body = #{~"items" => Items, ~"total" => Total, ~"page" => Page},
    {roadrunner_resp:json(200, Body), Req}.

get(Req) ->
    Id = id_from_path(Req),
    case ets:lookup(?CACHE, Id) of
        [{Id, Body}] ->
            {cached_json(Body, ~"HIT"), Req};
        [] ->
            case roadrunner_httparena_db:query(read, [binary_to_integer(Id)]) of
                {ok, _, [Row]} ->
                    Item = roadrunner_httparena_items:row_to_json(Row),
                    Body = iolist_to_binary(json:encode(Item)),
                    ets:insert(?CACHE, {Id, Body}),
                    {cached_json(Body, ~"MISS"), Req};
                {ok, _, []} ->
                    {roadrunner_resp:not_found(), Req};
                {error, _} ->
                    {roadrunner_resp:internal_error(), Req}
            end
    end.

%% Cache stores the already-encoded JSON body, so a cache hit ships the
%% bytes verbatim instead of re-encoding the item map every request;
%% `roadrunner_resp:body/4` folds in the `x-cache` marker in one call.
cached_json(Body, CacheStatus) ->
    roadrunner_resp:body(200, ~"application/json", [{~"x-cache", CacheStatus}], Body).

create(Req) ->
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    #{
        ~"id" := Id,
        ~"name" := Name,
        ~"category" := Category,
        ~"price" := Price,
        ~"quantity" := Quantity
    } = json:decode(Body),
    case roadrunner_httparena_db:query(create, [Id, Name, Category, Price, Quantity]) of
        {ok, 1} ->
            ets:delete(?CACHE, integer_to_binary(Id)),
            {roadrunner_resp:status(201), Req2};
        _ ->
            {roadrunner_resp:internal_error(), Req2}
    end.

update(Req) ->
    Id = id_from_path(Req),
    {ok, Body, Req2} = roadrunner_req:read_body(Req),
    #{
        ~"name" := Name,
        ~"category" := Category,
        ~"price" := Price,
        ~"quantity" := Quantity
    } = json:decode(Body),
    case roadrunner_httparena_db:query(update, [binary_to_integer(Id), Name, Category, Price, Quantity]) of
        {ok, 1} ->
            ets:delete(?CACHE, Id),
            {roadrunner_resp:status(200), Req2};
        {ok, 0} ->
            {roadrunner_resp:not_found(), Req2};
        _ ->
            {roadrunner_resp:internal_error(), Req2}
    end.

id_from_path(Req) ->
    #{~"id" := Id} = roadrunner_req:bindings(Req),
    Id.

qs_int(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {Key, V} when is_binary(V) -> roadrunner_httparena_handler:bin_int(V, Default);
        _ -> Default
    end.

qs_bin(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {Key, V} when is_binary(V) -> V;
        _ -> Default
    end.

clamp(N, Lo, _Hi) when N < Lo -> Lo;
clamp(N, _Lo, Hi) when N > Hi -> Hi;
clamp(N, _Lo, _Hi) -> N.
