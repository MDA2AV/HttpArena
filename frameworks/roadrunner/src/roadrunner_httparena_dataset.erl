-module(roadrunner_httparena_dataset).

-export([load/0, items/0]).

-define(KEY, {?MODULE, items}).

-spec load() -> ok.
load() ->
    Path = path(),
    {ok, Raw} = file:read_file(Path),
    Items = json:decode(Raw),
    persistent_term:put(?KEY, Items),
    ok.

-spec items() -> [map()].
items() ->
    persistent_term:get(?KEY).

path() ->
    case os:getenv("DATASET_PATH") of
        false ->
            application:get_env(roadrunner_httparena, dataset_path, "/data/dataset.json");
        Env ->
            Env
    end.
