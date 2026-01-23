////
//// Mission: own a continuous runner port for one instance.
////
//// Responsibilities:
//// - Start a continuous server via `saar/bridge/runner.start_server`.
//// - Stop the server reliably by owning the underlying BEAM `Port`.
//// - Provide a small message API (`stop`) for higher-level actors.
////
//// Non-responsibilities:
//// - Any instance lifecycle decisions (handled by `saar/core/agent_manager`).
//// - Interpreting runner events beyond stop/exit.
////
//// Relationships:
//// - Used as an `AgentResource` payload by `saar/core/agent`.
//// - Wraps `saar/bridge/runner`.

import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/otp/actor
import saar/bridge/port_process
import saar/bridge/runner
import saar/bridge/runner_contract
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/input as types_input
import saar/types/log as types_log
import saar/types/output as types_output
import saar/types/runner as types_runner

pub opaque type PortOwnerRef {
  PortOwnerRef(subject: process.Subject(Msg), pid: process.Pid)
}

type Msg {
  Stop
  StopSync(process.Subject(Nil))
  CheckExit(process.Subject(Bool))
  PortExited
}

fn subject(ref: PortOwnerRef) -> process.Subject(Msg) {
  let PortOwnerRef(subject: subject, ..) = ref
  subject
}

type State {
  Running(
    server: runner.ServerHandle,
    log_sink: fn(types_log.LogEvent) -> Nil,
    instance_id: types_core.InstanceId,
    trace_id: types_core.TraceId,
    exited: Bool,
  )
}

pub fn start_link(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types_input.SaarInput,
  config: types_config.SaarConfig,
  assigned_port: option.Option(Int),
  init_timeout_ms: Int,
  log_sink: fn(types_log.LogEvent) -> Nil,
  instance_id: types_core.InstanceId,
  trace_id: types_core.TraceId,
) -> actor.StartResult(PortOwnerRef) {
  actor.new_with_initialiser(init_timeout_ms, fn(self) {
    case
      runner.start_server(
        runner_path,
        runner_args,
        env,
        cwd,
        input,
        config,
        assigned_port,
      )
    {
      Ok(server) -> {
        let pump_pid =
          spawn_log_pump(server.process, log_sink, instance_id, trace_id, self)
        port_process.connect(server.process, pump_pid)
        actor.initialised(Running(
          server: server,
          log_sink: log_sink,
          instance_id: instance_id,
          trace_id: trace_id,
          exited: False,
        ))
        |> actor.returning(PortOwnerRef(self, process.self()))
        |> Ok
      }

      Error(err) -> {
        log_sink(types_log.log_event(
          types_log.AppLog,
          "[error] " <> interaction_error_string(err),
          option.Some(trace_id),
          instance_id,
        ))
        Error(interaction_error_string(err))
      }
    }
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn stop_async(ref: PortOwnerRef) -> Nil {
  process.send(subject(ref), Stop)
  Nil
}

pub fn stop(ref: PortOwnerRef, timeout_ms: Int) -> Result(Nil, Nil) {
  let reply_to = process.new_subject()
  process.send(subject(ref), StopSync(reply_to))

  case process.receive(reply_to, timeout_ms) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

pub fn detect_exit(ref: PortOwnerRef, timeout_ms: Int) -> Result(Bool, Nil) {
  let reply_to = process.new_subject()
  process.send(subject(ref), CheckExit(reply_to))

  case process.receive(reply_to, timeout_ms) {
    Ok(result) -> Ok(result)
    Error(_) -> Error(Nil)
  }
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Stop -> {
      stop_server_best_effort(state)
      actor.stop()
    }

    StopSync(reply_to) -> {
      process.send(reply_to, Nil)
      stop_server_best_effort(state)
      actor.stop()
    }

    CheckExit(reply_to) -> {
      let #(exited, next_state) = detect_server_exit(state)
      process.send(reply_to, exited)
      actor.continue(next_state)
    }

    PortExited -> {
      let Running(
        server: server,
        log_sink: log_sink,
        instance_id: instance_id,
        trace_id: trace_id,
        ..,
      ) = state
      actor.continue(Running(
        server: server,
        log_sink: log_sink,
        instance_id: instance_id,
        trace_id: trace_id,
        exited: True,
      ))
    }
  }
}

fn stop_server_best_effort(state: State) -> Nil {
  let Running(server: server, ..) = state
  runner.stop_server(server)
}

fn detect_server_exit(state: State) -> #(Bool, State) {
  let Running(
    server: server,
    log_sink: log_sink,
    instance_id: instance_id,
    trace_id: trace_id,
    exited: exited,
  ) = state
  case exited {
    True -> #(True, state)
    False ->
      case runner.detect_server_exit(server, trace_id) {
        Ok(_) -> #(False, state)
        Error(err) -> {
          log_sink(types_log.log_event(
            types_log.AppLog,
            "[error] " <> interaction_error_string(err),
            option.Some(trace_id),
            instance_id,
          ))
          #(
            True,
            Running(
              server: server,
              log_sink: log_sink,
              instance_id: instance_id,
              trace_id: trace_id,
              exited: True,
            ),
          )
        }
      }
  }
}

fn spawn_log_pump(
  port_proc: port_process.PortProcess,
  log_sink: fn(types_log.LogEvent) -> Nil,
  instance_id: types_core.InstanceId,
  trace_id: types_core.TraceId,
  owner: process.Subject(Msg),
) -> process.Pid {
  process.spawn(fn() {
    log_pump_loop(port_proc, log_sink, instance_id, trace_id, owner)
  })
}

fn log_pump_loop(
  port_proc: port_process.PortProcess,
  log_sink: fn(types_log.LogEvent) -> Nil,
  instance_id: types_core.InstanceId,
  trace_id: types_core.TraceId,
  owner: process.Subject(Msg),
) -> Nil {
  let #(next_process, outcome) = port_process.read_line(port_proc, 50)

  case outcome {
    Ok(line) -> {
      case runner_contract.decode_event(line) {
        Ok(types_runner.RunnerEventLog(message: msg, level: level)) -> {
          let line = "[" <> level <> "] " <> msg
          let event =
            types_log.log_event(
              types_log.AppLog,
              line,
              option.Some(trace_id),
              instance_id,
            )
          log_sink(event)
        }

        Ok(_) -> Nil

        Error(_) -> {
          log_sink(types_log.log_event(
            types_log.AppLog,
            "[raw] " <> line,
            option.Some(trace_id),
            instance_id,
          ))
        }
      }

      log_pump_loop(next_process, log_sink, instance_id, trace_id, owner)
    }

    Error(port_process.PortExited(code)) -> {
      log_sink(types_log.log_event(
        types_log.AppLog,
        "[error] runner exited with code " <> int.to_string(code),
        option.Some(trace_id),
        instance_id,
      ))
      process.send(owner, PortExited)
      Nil
    }
    Error(_) ->
      log_pump_loop(next_process, log_sink, instance_id, trace_id, owner)
  }
}

fn interaction_error_string(err: types_output.InteractionError) -> String {
  let types_output.InteractionError(message: msg, ..) = err
  msg
}
