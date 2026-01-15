%% Custom SIGTERM handler for SAD.
%%
%% This module is installed as a `gen_event` handler on `erl_signal_server`.
%% It forwards `sigterm` events to a target process as `{sad_sigterm}` and does
%% not call `init:stop/0` directly.

-module(sad_signal_handler).

-behaviour(gen_event).

-export([install/1]).

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

install(TargetPid) when is_pid(TargetPid) ->
    %% Ensure SIGTERM is delivered to `erl_signal_server`.
    catch os:set_signal(sigterm, handle),
    %% Remove the default handler so SIGTERM does not immediately stop the VM.
    catch gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
    %% Ensure idempotent installs.
    catch gen_event:delete_handler(erl_signal_server, ?MODULE, []),
    gen_event:add_handler(erl_signal_server, ?MODULE, [TargetPid]).

init([TargetPid]) ->
    {ok, TargetPid}.

handle_event(sigterm, TargetPid) ->
    TargetPid ! {sad_sigterm},
    {ok, TargetPid};
handle_event(_Event, State) ->
    {ok, State}.

handle_call(_Request, State) ->
    {ok, ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Args, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
