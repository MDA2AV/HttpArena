-module(roadrunner_httparena_cache).

-export([new/0, fetch/3, delete/1]).

-define(TAB, ?MODULE).

%% The production-stack read cache: one in-process ETS table, the
%% natural cache for a single BEAM node. Each entry carries its own
%% expiry, so an expired entry is simply replaced by the next miss and
%% no sweeper runs; the key space is bounded by the rows that exist.
-spec new() -> ok.
new() ->
    ?TAB = ets:new(?TAB, [
        named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}
    ]),
    ok.

%% Cache-aside: a fresh entry answers `{hit, Value}`; otherwise `Load`
%% runs and a found value is kept for `TtlMs` before `{miss, Value}`.
-spec fetch(term(), pos_integer(), fun(() -> {ok, term()} | not_found)) ->
    {hit, term()} | {miss, term()} | not_found.
fetch(Key, TtlMs, Load) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TAB, Key) of
        [{_, Expires, Value}] when Expires > Now ->
            {hit, Value};
        _ ->
            case Load() of
                {ok, Value} ->
                    true = ets:insert(?TAB, {Key, Now + TtlMs, Value}),
                    {miss, Value};
                not_found ->
                    not_found
            end
    end.

-spec delete(term()) -> ok.
delete(Key) ->
    true = ets:delete(?TAB, Key),
    ok.
