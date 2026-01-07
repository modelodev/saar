-module(sad_ffi).
-export([now_ms/0, open_port/5, port_send/2, port_close/1, port_receive/2]).

now_ms() ->
    erlang:monotonic_time(millisecond).

open_port(Command, Args, Env, Cd, MaxRunnerEventBytes) ->
    EnvList = env_pairs(Env),
    Opts = [
        {args, Args},
        {env, EnvList},
        {cd, Cd},
        binary,
        exit_status,
        use_stdio,
        {line, MaxRunnerEventBytes}
    ],
    try
        Port = erlang:open_port({spawn_executable, Command}, Opts),
        {ok, Port}
    catch
        _:Reason -> {error, format_error(Reason)}
    end.

port_send(Port, Data) ->
    erlang:port_command(Port, Data),
    nil.

port_close(Port) ->
    erlang:port_close(Port),
    nil.

port_receive(Port, TimeoutMs) ->
    receive
        {Port, {data, {eol, Line}}} -> {ok, {port_data_eol, Line}};
        {Port, {data, {noeol, Line}}} -> {ok, {port_data_noeol, Line}};
        {Port, {data, Line}} -> {ok, {port_data_noeol, Line}};
        {Port, {exit_status, Status}} -> {ok, {port_exit, Status}}
    after
        TimeoutMs -> {error, nil}
    end.

env_pairs(Env) ->
    [binary_to_list(Key) ++ "=" ++ binary_to_list(Value) || {Key, Value} <- Env].

format_error(Reason) ->
    lists:flatten(io_lib:format("~p", [Reason])).
