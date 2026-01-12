////
//// Mission: placeholder AgentManagerActor for the core OTP skeleton.
////
//// Responsibilities:
//// - Provide a stable, always-present process in the supervision tree.
//// - Expose the `AgentManagerMsg` subject for the gateway to depend on.
////
//// Non-responsibilities:
//// - Starting/stopping agents (implemented in later sprints).
//// - Coordinating cleanup, registry updates, or worker supervision.
////
//// Relationships:
//// - Started under `sad/core/root_supervisor`.
//// - Receives `sad/core/messages.AgentManagerMsg`.

import gleam/erlang/process
import gleam/otp/actor
import sad/core/messages

pub fn start(
  name: process.Name(messages.AgentManagerMsg),
) -> actor.StartResult(process.Subject(messages.AgentManagerMsg)) {
  actor.new(Nil)
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: Nil,
  msg: messages.AgentManagerMsg,
) -> actor.Next(Nil, messages.AgentManagerMsg) {
  case msg {
    messages.StartAgent(_args, reply_to) -> {
      process.send(
        reply_to,
        Error(messages.StartChildFailed("not_implemented")),
      )
      actor.continue(state)
    }

    messages.StopAgent(_instance_id, reply_to) -> {
      process.send(reply_to, Error(messages.AgentNotFound))
      actor.continue(state)
    }

    messages.DeleteAgent(_instance_id, reply_to) -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(state)
    }

    messages.DeleteWorkerDone(_instance_id, _result) -> actor.continue(state)

    messages.DeleteWorkerDown(_down) -> actor.continue(state)

    messages.ListAgents(reply_to) -> {
      process.send(reply_to, [])
      actor.continue(state)
    }
  }
}
