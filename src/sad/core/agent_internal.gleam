////
//// Mission: provide a narrow, internal API for injecting AgentActor events.
////
//// Responsibilities:
//// - Offer functions for bridge/workers to emit internal events into an AgentActor.
//// - Keep the public Agent API free from internal message construction.
////
//// Non-responsibilities:
//// - Exposing the AgentActor message protocol as an API for the gateway.
//// - Performing any IO or business logic; this module only forwards messages.
////
//// Relationships:
//// - Wraps `sad/core/agent` internal send helpers.

import gleam/option
import sad/core/agent
import sad/types/log as types_log
import sad/types/output as types_output

pub fn provisioning_done(
  agent_ref: agent.AgentRef,
  outcome: Result(#(agent.AgentState, option.Option(Int)), String),
) -> Nil {
  agent.internal_provisioning_done(agent_ref, outcome)
}

pub fn ingest_log(agent_ref: agent.AgentRef, event: types_log.LogEvent) -> Nil {
  agent.internal_ingest_log(agent_ref, event)
}

pub fn interaction_done(
  agent_ref: agent.AgentRef,
  result: Result(types_output.InteractionResult, types_output.InteractionError),
) -> Nil {
  agent.internal_interaction_done(agent_ref, result)
}

pub fn server_died(agent_ref: agent.AgentRef, exit_code: Int) -> Nil {
  agent.internal_server_died(agent_ref, exit_code)
}

pub fn terminate(agent_ref: agent.AgentRef, reason: agent.StopReason) -> Nil {
  agent.terminate(agent_ref, reason)
}
