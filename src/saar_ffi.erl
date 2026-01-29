-module(saar_ffi).
-export([
    now_ms/0,
    message_queue_len/1,
    open_port/4,
    port_connect/2,
    port_send/2,
    port_close/1,
    port_receive/2,
    check_port_available/2,
    safe_hackney_send/5
]).

now_ms() ->
    erlang:monotonic_time(millisecond).

message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        _ -> 0
    end.

open_port(Command, Args, Env, Cd) ->
    try
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
        Port = erlang:open_port({spawn_executable, CommandList}, Opts),
        {ok, Port}
    catch
        _:Reason -> {error, format_error(Reason)}
    end.

port_connect(Port, Pid) ->
    try erlang:port_connect(Port, Pid) of
        _ -> nil
    catch
        _:_ -> nil
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

check_port_available(Host, Port) ->
    try
        Ip = host_to_ip(to_list(Host)),
        Opts = [binary, {active, false}, {reuseaddr, true}, {ip, Ip}],
        case gen_tcp:listen(Port, Opts) of
            {ok, Socket} ->
                gen_tcp:close(Socket),
                {ok, nil};
            {error, eaddrinuse} -> {error, <<"in_use">>};
            {error, eacces} -> {error, <<"permission_denied">>};
            {error, eperm} -> {error, <<"permission_denied">>};
            {error, einval} -> {error, <<"invalid_host">>};
            {error, Reason1} -> {error, format_error(Reason1)}
        end
    catch
        _:badarg -> {error, <<"invalid_host">>};
        _:Reason2 -> {error, format_error(Reason2)}
    end.

safe_hackney_send(Method, Url, Headers, Body, Options) ->
    ensure_hackney_started(),
    try
        MethodAtom = normalize_method(Method),
        case hackney:request(MethodAtom, Url, Headers, Body, Options) of
            {ok, Status, ResponseHeaders, <<Binary>>} ->
                {ok, {binary_response, Status, ResponseHeaders, Binary}};

            {ok, Status, ResponseHeaders, ClientRef} ->
                {ok, {client_ref_response, Status, ResponseHeaders, ClientRef}};

            {ok, Status, ResponseHeaders} ->
                {ok, {empty_response, Status, ResponseHeaders}};

            {ok, ClientRef} ->
                {ok, {async_response, ClientRef}};

            {error, {closed, PartialBody}} ->
                {error, {connection_closed, PartialBody}};

            {error, Error} ->
                {error, {other, Error}}
        end
    catch
        _:Reason ->
            {error, {other, {Reason, Method, is_atom(Method), Url}}}
    end.

ensure_hackney_started() ->
    case erlang:whereis(hackney_sup) of
        undefined ->
            try
                case hackney_sup:start_link() of
                    {ok, _} -> ok;
                    {error, _} -> ok;
                    _ -> ok
                end
            catch
                _:_ -> ok
            end;
        _ -> ok
    end.

env_pairs(Env) ->
    [{to_list(Key), to_list(Value)} || {Key, Value} <- Env].

normalize_method(Method) when is_atom(Method) ->
    Method;
normalize_method({other, Value}) ->
    list_to_atom(string:lowercase(to_list(Value)));
normalize_method(Method) ->
    Method.

format_error(Reason) ->
    list_to_binary(lists:flatten(io_lib:format("~p", [Reason]))).

arg_list(Args) ->
    [to_list(Arg) || Arg <- Args].

to_list(Value) when is_binary(Value) ->
    binary_to_list(Value);
 to_list(Value) when is_list(Value) ->
    Value.

host_to_ip("localhost") -> {127, 0, 0, 1};
host_to_ip("0.0.0.0") -> {0, 0, 0, 0};
host_to_ip(Host) ->
    case string:tokens(Host, ".") of
        [A, B, C, D] ->
            {list_to_integer(A), list_to_integer(B), list_to_integer(C), list_to_integer(D)};
        _ -> erlang:error(badarg)
    end.


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
