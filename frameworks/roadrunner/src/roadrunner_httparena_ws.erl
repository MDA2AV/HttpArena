-module(roadrunner_httparena_ws).
-behaviour(roadrunner_ws_handler).

-export([handle_frame/2]).

handle_frame(#{opcode := text, payload := Payload}, State) ->
    {reply, [{text, Payload}], State};
handle_frame(#{opcode := binary, payload := Payload}, State) ->
    {reply, [{binary, Payload}], State};
handle_frame(_, State) ->
    {ok, State}.
