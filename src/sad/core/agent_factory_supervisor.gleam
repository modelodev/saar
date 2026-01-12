////
//// Mission: host the dynamic factory supervisor used to spawn AgentActor processes.
////
//// Responsibilities:
//// - Start a named `factory_supervisor` for agent instances.
//// - Configure child restart policy (`Temporary` for v0).
////
//// Non-responsibilities:
//// - Implementing the AgentActor itself (introduced in later sprints).
//// - Performing registry or profile coordination.
////
//// Relationships:
//// - Started under `sad/core/root_supervisor`.
//// - Looked up by name via `factory_supervisor.get_by_name`.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import sad/core/agent
import sad/core/messages

pub fn start(
  name: process.Name(
    factory_supervisor.Message(messages.StartArgs, agent.AgentRef),
  ),
) -> actor.StartResult(
  factory_supervisor.Supervisor(messages.StartArgs, agent.AgentRef),
) {
  let template = fn(_args: messages.StartArgs) {
    Error(actor.InitFailed("agent_not_implemented"))
  }

  factory_supervisor.worker_child(template)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.named(name)
  |> factory_supervisor.start
}
