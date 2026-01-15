-module(daemon).

-export([
    daemonize/4,
    kill_process/2,
    process_alive/1
]).

daemonize(Command, Args, PidFile, LogFile) ->
    try
        Shell = daemon_shell_command(Command, Args, LogFile),
        case run_sh_capture(Shell) of
            {ok, Output} ->
                case parse_pid(Output) of
                    {ok, Pid} ->
                        ok = file:write_file(to_list(PidFile), integer_to_list(Pid) ++ "\n"),
                        {ok, Pid};
                    {error, Reason} -> {error, Reason}
                end;
            {error, Reason2} -> {error, Reason2}
        end
    catch
        _:Reason3 -> {error, format_error(Reason3)}
    end.

kill_process(Pid, TimeoutMs) ->
    case process_alive(Pid) of
        false -> {error, <<"not_running">>};
        true ->
            case send_signal("-TERM", Pid) of
                ok ->
                    case wait_until_dead(Pid, TimeoutMs) of
                        ok -> {ok, nil};
                        timeout ->
                            case send_signal("-KILL", Pid) of
                                ok -> {ok, nil};
                                {error, Reason1} -> {error, Reason1}
                            end
                    end;
                {error, Reason2} -> {error, Reason2}
            end
    end.

process_alive(Pid) ->
    run_cmd("/bin/kill", ["-0", integer_to_list(Pid)]) =:= 0.

daemon_shell_command(Command, Args, LogFile) ->
    QuotedCommand = shell_quote(Command),
    QuotedArgs = join_quoted_args(Args),
    QuotedLog = shell_quote(LogFile),
    lists:flatten([
        "nohup ",
        QuotedCommand,
        " ",
        QuotedArgs,
        " >> ",
        QuotedLog,
        " 2>&1 & echo $!"
    ]).

run_sh_capture(ShellCommand) ->
    Port = erlang:open_port(
        {spawn_executable, "/bin/sh"},
        [
            binary,
            exit_status,
            {args, ["-c", ShellCommand]}
        ]
    ),
    collect_port_output(Port, <<>>).

collect_port_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port_output(Port, <<Acc/binary, (ensure_binary(Data))/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} ->
            {error, list_to_binary(io_lib:format("exit_status=~p", [Status]))}
    after
        5000 -> {error, <<"timeout">>}
    end.

parse_pid(Output) ->
    Trimmed = string:trim(to_list(Output)),
    case Trimmed of
        [] -> {error, <<"empty_pid">>};
        _ ->
            case catch list_to_integer(Trimmed) of
                Pid when is_integer(Pid), Pid > 0 -> {ok, Pid};
                _ -> {error, <<"invalid_pid">>}
            end
    end.

send_signal(Signal, Pid) ->
    Status = run_cmd("/bin/kill", [Signal, integer_to_list(Pid)]),
    case Status of
        0 -> ok;
        _ -> {error, list_to_binary(io_lib:format("kill_failed=~p", [Status]))}
    end.

wait_until_dead(_Pid, TimeoutMs) when TimeoutMs =< 0 -> timeout;
wait_until_dead(Pid, TimeoutMs) ->
    case process_alive(Pid) of
        false -> ok;
        true ->
            SleepMs = 50,
            timer:sleep(SleepMs),
            wait_until_dead(Pid, TimeoutMs - SleepMs)
    end.

run_cmd(Exe, Args) ->
    Port = erlang:open_port(
        {spawn_executable, Exe},
        [binary, exit_status, stderr_to_stdout, {args, Args}]
    ),
    wait_exit_status(Port).

wait_exit_status(Port) ->
    receive
        {Port, {exit_status, Status}} -> Status;
        {Port, {data, _}} -> wait_exit_status(Port)
    after
        5000 -> 1
    end.

shell_quote(Value) ->
    [$', escape_single_quotes(to_list(Value)), $'].

escape_single_quotes([]) -> [];
escape_single_quotes([$' | Rest]) -> [$', $\\, $', $' | escape_single_quotes(Rest)];
escape_single_quotes([C | Rest]) -> [C | escape_single_quotes(Rest)].

join_quoted_args([]) -> "";
join_quoted_args(Args) ->
    lists:flatten(lists:join(" ", [shell_quote(A) || A <- Args])).

to_list(Value) when is_binary(Value) -> binary_to_list(Value);
to_list(Value) when is_list(Value) -> Value.

ensure_binary(Value) when is_binary(Value) -> Value;
ensure_binary(Value) when is_list(Value) -> list_to_binary(Value).

format_error(Reason) ->
    list_to_binary(lists:flatten(io_lib:format("~p", [Reason]))).
