-module(nhttp_httparena_static).

-export([serve/2]).

-define(STATIC_DIR, <<"/data/static/">>).

-define(IS_NAME_CHAR(C),
    ((C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $- orelse C =:= $_)
).

-define(IS_OWS(C), (C =:= $\s orelse C =:= $\t)).

-type coding() :: br | gzip.
-type qvalue() :: 0..1000.

-spec serve(binary(), nhttp:request()) -> nhttp_lib:response().
serve(Name, Req) ->
    case media_type(Name) of
        {ok, Type, compressible} ->
            Codings = accepted_codings(nhttp_req:header(<<"accept-encoding">>, Req)),
            Headers = [{<<"content-type">>, Type}, {<<"vary">>, <<"accept-encoding">>}],
            reply(read(path(Name), Codings), Headers);
        {ok, Type, identity} ->
            reply(read(path(Name), []), [{<<"content-type">>, Type}]);
        error ->
            nhttp_resp:not_found()
    end.

path(Name) ->
    <<?STATIC_DIR/binary, Name/binary>>.

-spec read(binary(), [coding()]) ->
    {ok, binary(), nhttp_lib:headers()}
    | {error, file:posix() | badarg | terminated | system_limit}.
read(Path, [Coding | Rest]) ->
    case file:read_file(<<Path/binary, (suffix(Coding))/binary>>, [raw]) of
        {ok, Body} -> {ok, Body, [{<<"content-encoding">>, token(Coding)}]};
        {error, enoent} -> read(Path, Rest);
        {error, _Reason} = Error -> Error
    end;
read(Path, []) ->
    case file:read_file(Path, [raw]) of
        {ok, Body} -> {ok, Body, []};
        {error, _Reason} = Error -> Error
    end.

reply({ok, Body, Encoding}, Headers) ->
    nhttp_resp:ok(Encoding ++ Headers, Body);
reply({error, enoent}, _Headers) ->
    nhttp_resp:not_found();
reply({error, eisdir}, _Headers) ->
    nhttp_resp:not_found();
reply({error, _Reason}, _Headers) ->
    nhttp_resp:internal_error().

suffix(br) -> <<".br">>;
suffix(gzip) -> <<".gz">>.

token(br) -> <<"br">>;
token(gzip) -> <<"gzip">>.

media_type(<<$., _/binary>>) ->
    error;
media_type(Name) ->
    case extension(Name, <<>>) of
        {ok, Ext} -> content_type(Ext);
        error -> error
    end.

extension(<<$., Rest/binary>>, _Ext) ->
    extension(Rest, Rest);
extension(<<C, Rest/binary>>, Ext) when ?IS_NAME_CHAR(C) ->
    extension(Rest, Ext);
extension(<<>>, Ext) ->
    {ok, Ext};
extension(_Rest, _Ext) ->
    error.

content_type(<<"css">>) -> {ok, <<"text/css">>, compressible};
content_type(<<"js">>) -> {ok, <<"application/javascript">>, compressible};
content_type(<<"mjs">>) -> {ok, <<"application/javascript">>, compressible};
content_type(<<"html">>) -> {ok, <<"text/html">>, compressible};
content_type(<<"json">>) -> {ok, <<"application/json">>, compressible};
content_type(<<"svg">>) -> {ok, <<"image/svg+xml">>, compressible};
content_type(<<"txt">>) -> {ok, <<"text/plain">>, compressible};
content_type(<<"xml">>) -> {ok, <<"application/xml">>, compressible};
content_type(<<"wasm">>) -> {ok, <<"application/wasm">>, compressible};
content_type(<<"woff2">>) -> {ok, <<"font/woff2">>, identity};
content_type(<<"woff">>) -> {ok, <<"font/woff">>, identity};
content_type(<<"webp">>) -> {ok, <<"image/webp">>, identity};
content_type(<<"avif">>) -> {ok, <<"image/avif">>, identity};
content_type(<<"png">>) -> {ok, <<"image/png">>, identity};
content_type(<<"jpg">>) -> {ok, <<"image/jpeg">>, identity};
content_type(<<"jpeg">>) -> {ok, <<"image/jpeg">>, identity};
content_type(<<"gif">>) -> {ok, <<"image/gif">>, identity};
content_type(<<"ico">>) -> {ok, <<"image/x-icon">>, identity};
content_type(_Ext) -> {ok, <<"application/octet-stream">>, identity}.

-spec accepted_codings(binary() | undefined) -> [coding()].
accepted_codings(undefined) ->
    [];
accepted_codings(Header) ->
    Elements = binary:split(Header, <<",">>, [global]),
    {Br, Gzip, Any} = lists:foldl(fun weigh/2, {undefined, undefined, 0}, Elements),
    preference(weight(Br, Any), weight(Gzip, Any)).

weigh(Element, {Br, Gzip, Any} = Acc) ->
    case coding(Element) of
        {<<"br">>, Q} -> {Q, Gzip, Any};
        {<<"gzip">>, Q} -> {Br, Q, Any};
        {<<"x-gzip">>, Q} -> {Br, Q, Any};
        {<<"*">>, Q} -> {Br, Gzip, Q};
        {_Other, _Q} -> Acc;
        error -> Acc
    end.

weight(undefined, Any) -> Any;
weight(Q, _Any) -> Q.

-spec preference(qvalue(), qvalue()) -> [coding()].
preference(Br, Gzip) when Br > 0, Br >= Gzip -> [br | [gzip || Gzip > 0]];
preference(Br, Gzip) when Gzip > 0 -> [gzip | [br || Br > 0]];
preference(_Br, _Gzip) -> [].

-spec coding(binary()) -> {binary(), qvalue()} | error.
coding(Element) ->
    case binary:split(Element, <<";">>) of
        [Coding] -> {nhttp_headers:to_lower(trim(Coding)), 1000};
        [Coding, Weight] -> weighted(nhttp_headers:to_lower(trim(Coding)), trim(Weight))
    end.

weighted(Coding, <<Q, $=, Value/binary>>) when Q =:= $q; Q =:= $Q ->
    case qvalue(Value) of
        {ok, Weight} -> {Coding, Weight};
        error -> error
    end;
weighted(_Coding, _Params) ->
    error.

-spec qvalue(binary()) -> {ok, qvalue()} | error.
qvalue(<<$0>>) ->
    {ok, 0};
qvalue(<<$0, $., Digits/binary>>) ->
    thousandths(Digits, 100, 0);
qvalue(<<$1>>) ->
    {ok, 1000};
qvalue(<<$1, $., Digits/binary>>) ->
    case thousandths(Digits, 100, 0) of
        {ok, 0} -> {ok, 1000};
        {ok, _AboveOne} -> error;
        error -> error
    end;
qvalue(_Value) ->
    error.

thousandths(<<D, Rest/binary>>, Scale, Acc) when D >= $0, D =< $9, Scale > 0 ->
    thousandths(Rest, Scale div 10, Acc + (D - $0) * Scale);
thousandths(<<>>, _Scale, Acc) ->
    {ok, Acc};
thousandths(_Rest, _Scale, _Acc) ->
    error.

trim(Bin) ->
    trim_trailing(trim_leading(Bin)).

trim_leading(<<C, Rest/binary>>) when ?IS_OWS(C) -> trim_leading(Rest);
trim_leading(Bin) -> Bin.

trim_trailing(Bin) ->
    Size = byte_size(Bin) - 1,
    case Bin of
        <<Head:Size/binary, C>> when ?IS_OWS(C) -> trim_trailing(Head);
        _NoTrailingOws -> Bin
    end.
