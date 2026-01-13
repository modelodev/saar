-module(sad_ffi).
-export([
    now_ms/0,
    message_queue_len/1,
    open_port/4,
    port_send/2,
    port_close/1,
    port_receive/2
]).

now_ms() ->
    erlang:monotonic_time(millisecond).

message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        _ -> 0
    end.

open_port(Command, Args, Env, Cd) ->
    EnvList = env_pairs(Env),
    ArgsList = arg_list(Args),
    CommandList = to_list(Command),
    CdList = to_list(Cd),
    Opts = [
        {args, ArgsList},
        {env, EnvList},
        {cd, CdList},
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

port_receive(Port, TimeoutMs) ->
    receive
        {Port, {data, Data}} -> {ok, {port_data_chunk, ensure_binary(Data)}};
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

ensure_binary(Value) when is_binary(Value) ->
    Value;
ensure_binary(Value) when is_list(Value) ->
    list_to_binary(Value).

maybe_return_exit_after_data(Port, Status) ->
    receive
        {Port, {data, Data}} ->
            self() ! {Port, {exit_status, Status}},
            {ok, {port_data_chunk, ensure_binary(Data)}}
    after
        0 -> {ok, {port_exit, Status}}
    end.
