-module(roadrunner_httparena_items).

-export([row_to_json/1]).

-spec row_to_json(tuple()) -> map().
row_to_json({Id, Name, Cat, Price, Qty, Active, TagsJsonb, RScore, RCount}) ->
    #{
        ~"id" => Id,
        ~"name" => Name,
        ~"category" => Cat,
        ~"price" => Price,
        ~"quantity" => Qty,
        ~"active" => Active,
        ~"tags" => json:decode(TagsJsonb),
        ~"rating" => #{~"score" => RScore, ~"count" => RCount}
    }.
