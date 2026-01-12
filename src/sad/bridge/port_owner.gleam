////
//// Mission: own a continuous runner port for one instance.
////
//// Responsibilities:
//// - Start a continuous server via `sad/bridge/runner.start_server`.
//// - Stop the server reliably by owning the underlying BEAM `Port`.
//// - Provide a small message API (`stop`) for higher-level actors.
////
//// Non-responsibilities:
//// - Any instance lifecycle decisions (handled by `sad/core/agent_manager`).
//// - Interpreting runner events beyond stop/exit.
////
//// Relationships:
//// - Used as an `AgentResource` payload by `sad/core/agent`.
//// - Wraps `sad/bridge/runner` and `sad/bridge/port_process`.

import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import sad/bridge/port_process
import sad/bridge/runner
import sad/types/config as types_config
import sad/types/input as types_input
import sad/types/output as types_output

pub type PortOwnerRef {
  PortOwnerRef(subject: process.Subject(Msg), pid: process.Pid)
}

pub fn pid(ref: PortOwnerRef) -> process.Pid {
  let PortOwnerRef(pid: pid, ..) = ref
  pid
}

pub fn subject(ref: PortOwnerRef) -> process.Subject(Msg) {
  let PortOwnerRef(subject: subject, ..) = ref
  subject
}

pub type Msg {
  Stop
  StopSync(process.Subject(Nil))
}

type State {
  Running(server: runner.ServerHandle)
  Stopping
}

pub fn start_link(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  input: types_input.SadInput,
  config: types_config.SadConfig,
  assigned_port: option.Option(Int),
  init_timeout_ms: Int,
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
      Ok(server) ->
        actor.initialised(Running(server))
        |> actor.returning(PortOwnerRef(self, process.self()))
        |> Ok

      Error(err) -> Error(interaction_error_string(err))
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

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Stop -> {
      stop_server_best_effort(state)
      process.kill(process.self())
      actor.continue(Stopping)
    }

    StopSync(reply_to) -> {
      process.send(reply_to, Nil)
      stop_server_best_effort(state)
      process.kill(process.self())
      actor.continue(Stopping)
    }
  }
}

fn stop_server_best_effort(state: State) -> Nil {
  case state {
    Running(server) -> stop_running_server(server)
    Stopping -> Nil
  }
}

fn stop_running_server(server: runner.ServerHandle) -> Nil {
  let runner.ServerHandle(process: proc, ..) = server

  // Don't close immediately; give the wrapper a chance to act on `stop`.
  port_process.send(proc, "{\"t\":\"stop\"}\n")
  drain_loop(proc, 80)
  port_process.close(proc)
}

fn drain_loop(port: port_process.PortProcess, attempts: Int) -> Nil {
  case attempts {
    0 -> Nil

    _ ->
      case port_process.receive(port, 50) {
        Ok(port_process.PortExit(_)) -> Nil
        Ok(_) -> drain_loop(port, attempts - 1)
        Error(_) -> drain_loop(port, attempts - 1)
      }
  }
}

fn interaction_error_string(err: types_output.InteractionError) -> String {
  let types_output.InteractionError(message: msg, ..) = err
  msg
}
