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
//// - Used as an `AgentResource` payload by `sad/core/agent_lifecycle`.
//// - Wraps `sad/bridge/runner`.

import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import sad/bridge/runner
import sad/types/config as types_config
import sad/types/input as types_input
import sad/types/output as types_output

pub opaque type PortOwnerRef {
  PortOwnerRef(subject: process.Subject(Msg), pid: process.Pid)
}

type Msg {
  Stop
  StopSync(process.Subject(Nil))
}

fn subject(ref: PortOwnerRef) -> process.Subject(Msg) {
  let PortOwnerRef(subject: subject, ..) = ref
  subject
}

type State {
  Running(server: runner.ServerHandle)
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
      actor.stop()
    }

    StopSync(reply_to) -> {
      process.send(reply_to, Nil)
      stop_server_best_effort(state)
      actor.stop()
    }
  }
}

fn stop_server_best_effort(state: State) -> Nil {
  let Running(server) = state
  runner.stop_server(server)
}

fn interaction_error_string(err: types_output.InteractionError) -> String {
  let types_output.InteractionError(message: msg, ..) = err
  msg
}
