-module(nhttp_httparena_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([dataset/0]).

-define(DATASET, {?MODULE, dataset}).

start(_StartType, _StartArgs) ->
    ok = persistent_term:put(?DATASET, load_dataset()),
    nhttp_httparena_sup:start_link().

stop(_State) ->
    ok.

dataset() ->
    persistent_term:get(?DATASET).

load_dataset() ->
    Path = os:getenv("DATASET_PATH", "/data/dataset.json"),
    case file:read_file(Path) of
        {ok, Json} -> json:decode(Json);
        {error, enoent} -> []
    end.
