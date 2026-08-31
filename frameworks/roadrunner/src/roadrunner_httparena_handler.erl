-module(roadrunner_httparena_handler).
-behaviour(roadrunner_handler).

-export([routes/0]).
-export([handle/1]).
-export([bin_int/2]).

-spec routes() -> [roadrunner_router:route()].
routes() ->
    [
        {~"/baseline11", ?MODULE, undefined},
        {~"/baseline2", ?MODULE, undefined},
        {~"/pipeline", ?MODULE, undefined},
        #{path => ~"/json/:count", handler => ?MODULE, middlewares => [roadrunner_compress]},
        {~"/echo", ?MODULE, undefined},
        {~"/async-db", ?MODULE, undefined},
        #{path => ~"/fortunes", handler => ?MODULE, middlewares => [roadrunner_compress]},
        {~"/crud/items", ?MODULE, undefined},
        {~"/crud/items/:id", ?MODULE, undefined},
        {~"/ws", ?MODULE, undefined},
        #{
            path => ~"/static/*path",
            handler => roadrunner_static,
            state => #{dir => static_dir(), cache_ttl_ms => 1000},
            middlewares => [roadrunner_compress]
        }
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
handle_route(~"/echo", Req) ->
    echo_endpoint(Req);
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

%% roadrunner_resp has no octet-stream builder, so the buffered
%% `{Status, Headers, Body}` triple is assembled here. `content-length`
%% comes from the collected body rather than from the request, which is
%% what makes the chunked case work: a chunked request carries no
%% `Content-Length` to forward, and an empty one still gets a `0`.
echo_endpoint(Req) ->
    {Body, Req2} = collect_body(Req, []),
    Resp =
        {200,
            [
                {~"content-type", ~"application/octet-stream"},
                {~"content-length", integer_to_binary(iolist_size(Body))}
            ],
            Body},
    {Resp, Req2}.

%% Read the request body in 64 KB chunks, keeping each one. With
%% `body_buffering => manual` on the listener, `read_body/2
%% #{length => 65536}` returns one chunk at a time; `read_body/2`
%% decodes chunked framing itself, so this is the same loop either way.
%% The chunks are accumulated in reverse and returned as `iodata()` --
%% the auto-buffered body is `iodata()` too, so nothing is flattened
%% before it goes back out on the wire.
collect_body(Req, Acc) ->
    case roadrunner_req:read_body(Req, #{length => 65536}) of
        {ok, Bytes, Req2} ->
            {lists:reverse([Bytes | Acc]), Req2};
        {more, Bytes, Req2} ->
            collect_body(Req2, [Bytes | Acc])
    end.

async_db_endpoint(Req) ->
    Qs = roadrunner_req:parse_qs(Req),
    Min = qs_int_from(~"min", Qs, 10),
    Max = qs_int_from(~"max", Qs, 50),
    Limit = clamp(qs_int_from(~"limit", Qs, 50), 1, 50),
    {Items, Count} =
        case roadrunner_httparena_db:query(async_db, [Min, Max, Limit]) of
            {ok, _Cols, Rows} ->
                lists:mapfoldl(
                    fun(R, N) -> {roadrunner_httparena_items:row_to_json(R), N + 1} end, 0, Rows
                );
            _ ->
                {[], 0}
        end,
    Body = #{~"count" => Count, ~"items" => Items},
    {roadrunner_resp:json(200, Body), Req}.

clamp(N, Lo, _Hi) when N < Lo -> Lo;
clamp(N, _Lo, Hi) when N > Hi -> Hi;
clamp(N, _Lo, _Hi) -> N.

fortunes_endpoint(Req) ->
    Rows =
        case roadrunner_httparena_db:query(fortunes, []) of
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
    Qs = roadrunner_req:parse_qs(Req),
    A = qs_int_from(~"a", Qs, 0),
    B = qs_int_from(~"b", Qs, 0),
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
    {Processed, ItemCount} =
        lists:mapfoldl(fun(I, N) -> {add_total(I, M), N + 1} end, 0, Items),
    Body = #{~"items" => Processed, ~"count" => ItemCount},
    {roadrunner_resp:json(200, Body), Req}.

add_total(#{~"price" := Price, ~"quantity" := Qty} = Item, M) ->
    Item#{~"total" => Price * Qty * M}.

binding_int(Key, Req, Default) ->
    case roadrunner_req:bindings(Req) of
        #{Key := V} when is_binary(V) -> bin_int(V, Default);
        _ -> Default
    end.

qs_int(Key, Req, Default) ->
    qs_int_from(Key, roadrunner_req:parse_qs(Req), Default).

qs_int_from(Key, Qs, Default) ->
    case lists:keyfind(Key, 1, Qs) of
        {Key, V} when is_binary(V) -> bin_int(V, Default);
        _ -> Default
    end.

%% Parse the leading (optionally signed) digits — the shape
%% `string:to_integer/1` accepted — without the unicode list
%% round-trip the string module pays per call.
bin_int(<<$-, Rest/binary>>, Default) ->
    case leading_digits(Rest, 0, false) of
        {ok, N} -> -N;
        error -> Default
    end;
bin_int(Bin, Default) ->
    case leading_digits(Bin, 0, false) of
        {ok, N} -> N;
        error -> Default
    end.

leading_digits(<<D, Rest/binary>>, Acc, _Any) when D >= $0, D =< $9 ->
    leading_digits(Rest, Acc * 10 + (D - $0), true);
leading_digits(_Rest, _Acc, false) ->
    error;
leading_digits(_Rest, Acc, true) ->
    {ok, Acc}.

%% A chunked or split-delivery body arrives as iodata (a list of
%% chunks), not one binary — flatten before parsing.
body_int(Body) ->
    bin_int(iolist_to_binary(Body), 0).
