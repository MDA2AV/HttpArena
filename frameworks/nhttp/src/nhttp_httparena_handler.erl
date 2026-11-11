-module(nhttp_httparena_handler).
-behaviour(nhttp_handler).

-export([init/1, handle_request/2, handle_request_body/3, handle_ws_frame/3]).

init(_Args) ->
    {ok, undefined}.

handle_request(#{path := <<"/ws">>} = Req, State) ->
    case nhttp_req:is_websocket(Req) of
        true -> {upgrade, websocket, State};
        false -> {reply, nhttp_resp:bad_request(), State}
    end;
handle_request(#{method := get, path := <<"/static/", Target/binary>>} = Req, State) ->
    {Name, _Query} = split_target(Target),
    {reply, nhttp_httparena_static:serve(Name, Req), State};
handle_request(#{method := get} = Req, State) ->
    {reply, respond(Req, <<>>), State};
handle_request(#{body := streaming} = Req, State) ->
    {accept_body, {Req, []}, State};
handle_request(Req, State) ->
    {reply, respond(Req, maps:get(body, Req, <<>>)), State}.

handle_request_body({data, Bytes}, {Req, Acc}, State) ->
    {accept_body, {Req, [Acc, Bytes]}, State};
handle_request_body({fin, _Trailers}, {Req, Acc}, State) ->
    {reply, respond(Req, Acc), State};
handle_request_body({abort, Reason}, _BodyState, State) ->
    {abort, Reason, State}.

handle_ws_frame(Frame, _Session, State) ->
    {reply, Frame, State}.

respond(#{path := Target}, Body) ->
    {Path, Query} = split_target(Target),
    route(Path, Query, Body).

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [Path, Query] -> {Path, Query};
        [Path] -> {Path, <<>>}
    end.

route(<<"/baseline11">>, Query, Body) ->
    baseline(Query, Body);
route(<<"/baseline2">>, Query, Body) ->
    baseline(Query, Body);
route(<<"/pipeline">>, _Query, _Body) ->
    nhttp_resp:ok([{<<"content-type">>, <<"text/plain">>}], <<"ok">>);
route(<<"/json/", Count/binary>>, Query, _Body) ->
    json(to_int(Count), multiplier(Query));
route(<<"/echo">>, _Query, Body) ->
    nhttp_resp:ok([{<<"content-type">>, <<"application/octet-stream">>}], Body);
route(<<"/delay/", Ms/binary>>, _Query, _Body) ->
    delay(to_int(Ms));
route(_Path, _Query, _Body) ->
    nhttp_resp:not_found().

baseline(Query, Body) ->
    Sum = query_sum(Query) + to_int(iolist_to_binary(Body)),
    nhttp_resp:ok([{<<"content-type">>, <<"text/plain">>}], integer_to_binary(Sum)).

json(Count, M) ->
    Items = take_items(Count, M, nhttp_httparena_app:dataset()),
    Body = json:encode(#{<<"items">> => Items, <<"count">> => length(Items)}),
    nhttp_resp:ok([{<<"content-type">>, <<"application/json">>}], iolist_to_binary(Body)).

take_items(0, _M, _Items) ->
    [];
take_items(_N, _M, []) ->
    [];
take_items(N, M, [#{<<"price">> := Price, <<"quantity">> := Qty} = Item | Rest]) ->
    [Item#{<<"total">> => Price * Qty * M} | take_items(N - 1, M, Rest)].

delay(Ms) ->
    timer:sleep(Ms),
    nhttp_resp:ok([{<<"content-type">>, <<"text/plain">>}], integer_to_binary(Ms)).

query_sum(Query) ->
    lists:foldl(fun add_param/2, 0, binary:split(Query, <<"&">>, [global])).

add_param(<<"a=", V/binary>>, Acc) -> Acc + to_int(V);
add_param(<<"b=", V/binary>>, Acc) -> Acc + to_int(V);
add_param(_Param, Acc) -> Acc.

multiplier(Query) ->
    lists:foldl(fun m_param/2, 1, binary:split(Query, <<"&">>, [global])).

m_param(<<"m=", V/binary>>, _Acc) -> to_int(V);
m_param(_Param, Acc) -> Acc.

to_int(<<$-, Rest/binary>>) -> -leading_digits(Rest, 0);
to_int(Bin) -> leading_digits(Bin, 0).

leading_digits(<<D, Rest/binary>>, Acc) when D >= $0, D =< $9 ->
    leading_digits(Rest, Acc * 10 + (D - $0));
leading_digits(_Rest, Acc) ->
    Acc.
