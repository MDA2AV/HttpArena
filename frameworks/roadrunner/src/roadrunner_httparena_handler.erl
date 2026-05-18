-module(roadrunner_httparena_handler).
-behaviour(roadrunner_handler).

-export([routes/0]).
-export([handle/1]).

-spec routes() -> [roadrunner_router:route()].
routes() ->
    [
        {~"/baseline11", ?MODULE, undefined},
        {~"/baseline2", ?MODULE, undefined},
        {~"/pipeline", ?MODULE, undefined},
        {~"/json/:count", ?MODULE, undefined},
        {~"/upload", ?MODULE, undefined},
        {~"/async-db", ?MODULE, undefined},
        {~"/fortunes", ?MODULE, undefined},
        {~"/crud/items", ?MODULE, undefined},
        {~"/crud/items/:id", ?MODULE, undefined},
        {~"/ws", ?MODULE, undefined},
        {~"/static/*path", roadrunner_static, #{dir => static_dir()}}
    ].

static_dir() ->
    case os:getenv("STATIC_DIR") of
        false -> ~"/data/static";
        D -> iolist_to_binary(D)
    end.

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    handle_route(roadrunner_req:path(Req), Req).

handle_route(~"/baseline11", Req) ->
    baseline(Req);
handle_route(~"/baseline2", Req) ->
    baseline(Req);
handle_route(~"/pipeline", Req) ->
    {roadrunner_resp:text(200, ~"ok"), Req};
handle_route(<<"/json/", _/binary>>, Req) ->
    json_endpoint(Req);
handle_route(~"/upload", Req) ->
    upload_endpoint(Req);
handle_route(~"/async-db", Req) ->
    async_db_endpoint(Req);
handle_route(~"/fortunes", Req) ->
    fortunes_endpoint(Req);
handle_route(~"/crud/items", Req) ->
    case roadrunner_req:method(Req) of
        ~"GET" -> roadrunner_httparena_crud:list(Req);
        ~"POST" -> roadrunner_httparena_crud:create(Req);
        _ -> {roadrunner_resp:status(405), Req}
    end;
handle_route(<<"/crud/items/", _/binary>>, Req) ->
    case roadrunner_req:method(Req) of
        ~"GET" -> roadrunner_httparena_crud:get(Req);
        ~"PUT" -> roadrunner_httparena_crud:update(Req);
        _ -> {roadrunner_resp:status(405), Req}
    end;
handle_route(~"/ws", Req) ->
    {{websocket, roadrunner_httparena_ws, undefined}, Req};
handle_route(_, Req) ->
    {roadrunner_resp:not_found(), Req}.

upload_endpoint(Req) ->
    {Count, Req2} = consume_body(Req, 0),
    {roadrunner_resp:text(200, integer_to_binary(Count)), Req2}.

%% Stream the request body in 64 KB chunks, discarding each chunk
%% after counting its bytes via `iolist_size/1` (the auto-buffered body
%% is `iodata()`, not `binary()`). With `body_buffering => manual` on
%% the listener, `read_body/2 #{length => 65536}` returns one chunk at
%% a time so peak memory stays bounded even for the 20 MB upload
%% validator case.
consume_body(Req, Acc) ->
    case roadrunner_req:read_body(Req, #{length => 65536}) of
        {ok, Bytes, Req2} ->
            {Acc + iolist_size(Bytes), Req2};
        {more, Bytes, Req2} ->
            consume_body(Req2, Acc + iolist_size(Bytes))
    end.

async_db_endpoint(Req) ->
    Min = qs_int(~"min", Req, 10),
    Max = qs_int(~"max", Req, 50),
    Limit = clamp(qs_int(~"limit", Req, 50), 1, 50),
    Sql = ~"""
    SELECT id, name, category, price, quantity, active, tags,
           rating_score, rating_count
      FROM items
     WHERE price BETWEEN $1 AND $2 LIMIT $3
    """,
    Items =
        case roadrunner_httparena_db:query(Sql, [Min, Max, Limit]) of
            {ok, _Cols, Rows} -> [roadrunner_httparena_items:row_to_json(R) || R <- Rows];
            _ -> []
        end,
    Body = #{~"count" => length(Items), ~"items" => Items},
    {roadrunner_resp:json(200, Body), Req}.

clamp(N, Lo, _Hi) when N < Lo -> Lo;
clamp(N, _Lo, Hi) when N > Hi -> Hi;
clamp(N, _Lo, _Hi) -> N.

fortunes_endpoint(Req) ->
    Rows =
        case roadrunner_httparena_db:query(~"SELECT id, message FROM fortune", []) of
            {ok, _Cols, R} -> R;
            _ -> []
        end,
    Runtime = {0, ~"Additional fortune added at request time."},
    Sorted = lists:keysort(2, [Runtime | Rows]),
    Body = render_fortunes(Sorted),
    {roadrunner_resp:html(200, Body), Req}.

render_fortunes(Rows) ->
    [
        ~"<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>",
        [render_fortune_row(Id, Msg) || {Id, Msg} <- Rows],
        ~"</table></body></html>"
    ].

render_fortune_row(Id, Msg) ->
    [~"<tr><td>", integer_to_binary(Id), ~"</td><td>", html_escape(Msg), ~"</td></tr>"].

html_escape(Bin) when is_binary(Bin) ->
    B1 = binary:replace(Bin, ~"&", ~"&amp;", [global]),
    B2 = binary:replace(B1, ~"<", ~"&lt;", [global]),
    binary:replace(B2, ~">", ~"&gt;", [global]).

baseline(Req) ->
    A = qs_int(~"a", Req, 0),
    B = qs_int(~"b", Req, 0),
    {BodyN, Req2} =
        case roadrunner_req:method(Req) of
            ~"POST" ->
                {ok, Body, ReqR} = roadrunner_req:read_body(Req),
                {body_int(Body), ReqR};
            _ ->
                {0, Req}
        end,
    {roadrunner_resp:text(200, integer_to_binary(A + B + BodyN)), Req2}.

json_endpoint(Req) ->
    Count = binding_int(~"count", Req, 0),
    M = qs_int(~"m", Req, 1),
    All = roadrunner_httparena_dataset:items(),
    Items = lists:sublist(All, max(0, Count)),
    Processed = [add_total(I, M) || I <- Items],
    Body = #{~"items" => Processed, ~"count" => length(Processed)},
    {roadrunner_resp:json(200, Body), Req}.

add_total(Item, M) ->
    Price = maps:get(~"price", Item),
    Qty = maps:get(~"quantity", Item),
    Item#{~"total" => Price * Qty * M}.

binding_int(Key, Req, Default) ->
    case roadrunner_req:bindings(Req) of
        #{Key := V} when is_binary(V) -> bin_int(V, Default);
        _ -> Default
    end.

qs_int(Key, Req, Default) ->
    case lists:keyfind(Key, 1, roadrunner_req:parse_qs(Req)) of
        {Key, V} when is_binary(V) -> bin_int(V, Default);
        _ -> Default
    end.

bin_int(<<>>, Default) ->
    Default;
bin_int(Bin, Default) ->
    case string:to_integer(Bin) of
        {N, _} when is_integer(N) -> N;
        _ -> Default
    end.

body_int(<<>>) -> 0;
body_int(Bin) -> bin_int(Bin, 0).
