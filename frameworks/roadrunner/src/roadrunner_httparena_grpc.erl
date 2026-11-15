-module(roadrunner_httparena_grpc).
-moduledoc """
`benchmark.BenchmarkService` from `proto/benchmark.proto`, one function per
method. Messages are the maps `benchmark_pb` (gpb) gives.
""".

-export([get_sum/2, stream_sum/2, collect_sum/1, echo_sum/1]).

%% Unary: the sum of `a` and `b`.
get_sum(#{} = Request, Stream) ->
    {reply, #{result => sum(Request)}, Stream}.

%% Server streaming: `count` replies, each the sum of `a` and `b`.
stream_sum(#{} = Request, Stream0) ->
    Reply = #{result => sum(Request)},
    Stream = send_n(maps:get(count, Request, 0), Reply, Stream0),
    {ok, Stream}.

send_n(N, Reply, Stream) when N > 0 ->
    send_n(N - 1, Reply, roadrunner_grpc:send(Reply, Stream));
send_n(_N, _Reply, Stream) ->
    Stream.

%% Client streaming: one reply with the total of every request.
collect_sum(Stream) ->
    collect_sum(Stream, 0).

collect_sum(Stream0, Total) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Request, Stream} -> collect_sum(Stream, int32(Total + sum(Request)));
        {eof, Stream} -> {reply, #{result => Total}, Stream}
    end.

%% Bidirectional streaming: one reply per request.
echo_sum(Stream0) ->
    case roadrunner_grpc:recv(Stream0) of
        {ok, Request, Stream} ->
            echo_sum(roadrunner_grpc:send(#{result => sum(Request)}, Stream));
        {eof, Stream} ->
            {ok, Stream}
    end.

%% proto3 omits fields left at zero, and int32 arithmetic wraps.
sum(Request) ->
    int32(maps:get(a, Request, 0) + maps:get(b, Request, 0)).

int32(N) ->
    ((N + 16#80000000) band 16#FFFFFFFF) - 16#80000000.
