-module(sad_ffi).
-export([
    now_ms/0,
    message_queue_len/1,
    open_port/5,
    port_send/2,
    port_close/1,
    port_connect/2,
    port_receive/2
]).

now_ms() ->
    erlang:monotonic_time(millisecond).

message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        _ -> 0
    end.

open_port(Command, Args, Env, Cd, MaxRunnerEventBytes) ->
    EnvList = env_pairs(Env),
    ArgsList = arg_list(Args),
    CommandList = to_list(Command),
    CdList = to_list(Cd),
    Opts = [
        {args, ArgsList},
        {env, EnvList},
        {cd, CdList},
        {line, MaxRunnerEventBytes},
        binary,
        exit_status,
        use_stdio
    ],
    try
        Port = erlang:open_port({spawn_executable, CommandList}, Opts),
        {ok, Port}
    catch
        _:Reason -> {error, format_error(Reason)}
    end.

port_send(Port, Data) ->
    try erlang:port_command(Port, Data) of
        _ -> nil
    catch
        _:_ -> nil
    end.

port_close(Port) ->
    try erlang:port_close(Port) of
        _ -> nil
    catch
        _:_ -> nil
    end.

port_connect(Port, Pid) ->
    try
        erlang:port_connect(Port, Pid),
        {ok, nil}
    catch
        _:Reason -> {error, format_error(Reason)}
    end.

port_receive(Port, TimeoutMs) ->
    receive
        {Port, {data, {eol, Line}}} -> {ok, {port_data_chunk, append_newline(Line)}};
        {Port, {data, {noeol, Line}}} -> {ok, {port_data_chunk, Line}};
        {Port, {data, Line}} -> {ok, {port_data_chunk, Line}};
        {Port, {exit_status, Status}} -> maybe_return_exit_after_data(Port, Status);
        {'EXIT', Port, normal} -> maybe_return_exit_after_data(Port, 0);
        {'EXIT', Port, _} -> maybe_return_exit_after_data(Port, 1)
    after
        TimeoutMs -> {error, nil}
    end.

env_pairs(Env) ->
    [{to_list(Key), to_list(Value)} || {Key, Value} <- Env].

format_error(Reason) ->
    lists:flatten(io_lib:format("~p", [Reason])).

arg_list(Args) ->
    [to_list(Arg) || Arg <- Args].

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_list(Value) when is_list(Value) ->
    Value.

append_newline(Line) when is_binary(Line) ->
    <<Line/binary, "\n">>;
append_newline(Line) when is_list(Line) ->
    Line ++ "\n".

maybe_return_exit_after_data(Port, Status) ->
    receive
        {Port, {data, {eol, Line}}} ->
            self() ! {Port, {exit_status, Status}},
            {ok, {port_data_chunk, append_newline(Line)}};
        {Port, {data, {noeol, Line}}} ->
            self() ! {Port, {exit_status, Status}},
            {ok, {port_data_chunk, Line}};
        {Port, {data, Line}} ->
            self() ! {Port, {exit_status, Status}},
            {ok, {port_data_chunk, Line}}
    after
        0 -> {ok, {port_exit, Status}}
    end.
