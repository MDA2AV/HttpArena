-module(roadrunner_httparena_fortunes).
-moduledoc """
The /fortunes page as an Arizona template: the static markup is the
template's, and every fortune is interpolated and HTML-escaped by the
engine. The page root carries `az_nodiff`, which its row template
inherits: it is rendered once per request with no live client to patch,
so it needs none of the markers Arizona keeps for updating a live page.
""".

-include_lib("arizona/include/arizona_stateless.hrl").

-export([render/1]).

-spec render(arizona_template:bindings()) -> arizona_template:template().
render(Bindings) ->
    ?html([
        ~"<!doctype html>",
        {html, [az_nodiff], [
            {head, [], {title, [], ~"Fortunes"}},
            {body, [],
                {table, [], [
                    {tr, [], [{th, [], ~"id"}, {th, [], ~"message"}]},
                    ?each(
                        fun({Id, Message}) ->
                            {tr, [], [{td, [], Id}, {td, [], Message}]}
                        end,
                        ?get(fortunes)
                    )
                ]}}
        ]}
    ]).
