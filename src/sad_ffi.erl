-module(sad_ffi).
-export([now_ms/0, open_port/5, port_send/2, port_close/1, port_receive/2, priv_dir/0]).

now_ms() ->
    erlang:monotonic_time(millisecond).

open_port(Command, Args, Env, Cd, MaxRunnerEventBytes) ->
    EnvList = env_pairs(Env),
    ArgsList = arg_list(Args),
    CommandList = to_list(Command),
    CdList = to_list(Cd),
    LineLimit = line_limit(MaxRunnerEventBytes),
    Opts = [
        {args, ArgsList},
        {env, EnvList},
        {cd, CdList},
        binary,
        exit_status,
        use_stdio,
        {line, LineLimit}
    ],
    try
        Port = erlang:open_port({spawn_executable, CommandList}, Opts),
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
        {Port, {exit_status, Status}} -> {ok, {port_exit, Status}};
        {'EXIT', Port, normal} -> {ok, {port_exit, 0}};
        {'EXIT', Port, _} -> {ok, {port_exit, 1}}
    after
        TimeoutMs -> {error, nil}
    end.

priv_dir() ->
    case code:priv_dir(sad) of
        {error, Reason} -> {error, format_error(Reason)};
        Dir -> {ok, list_to_binary(Dir)}
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

line_limit(MaxRunnerEventBytes) when is_integer(MaxRunnerEventBytes), MaxRunnerEventBytes > 0 ->
    case MaxRunnerEventBytes > 65535 of
        true -> 65535;
        false -> MaxRunnerEventBytes
    end;
line_limit(_) ->
    65535.
