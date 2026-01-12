////
//// Mission: provide a small, typed API over the `AgentManagerActor` message protocol.
////
//// Responsibilities:
//// - Encapsulate message construction for boundary callers.
//// - Ensure timeouts are always explicit at call sites.
////
//// Non-responsibilities:
//// - Implementing AgentManager behavior (see `sad/core/agent_manager`).
//// - Applying default timeouts.
////
//// Relationships:
//// - Uses `sad/otp/safe_call.call_within` for failure-safe calls.
//// - Targets `sad/core/messages.AgentManagerMsg`.

import gleam/dict
import gleam/erlang/process
import gleam/result
import sad/core/agent
import sad/core/messages
import sad/otp/safe_call
import sad/types/agent as types_agent
import sad/types/core as types_core

/// Error returned by the API layer when calling an actor.
///
/// `CallFailed` indicates the actor could not be reached (down or timed out).
/// `ActorError` carries the domain error returned by the actor.
pub type ApiCallError(e) {
  CallFailed(safe_call.CallError)
  ActorError(e)
}

pub fn create_agent(
  manager: process.Subject(messages.AgentManagerMsg),
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
  init_params: dict.Dict(String, types_core.Value),
  timeout_ms: Int,
) -> Result(agent.AgentRef, ApiCallError(messages.StartError)) {
  safe_call.call_within(manager, timeout_ms, fn(reply_to) {
    messages.CreateAgent(profile_id, instance_id, init_params, reply_to)
  })
  |> result.map_error(CallFailed)
  |> result.try(fn(reply) { reply |> result.map_error(ActorError) })
}

pub fn start_agent(
  manager: process.Subject(messages.AgentManagerMsg),
  args: messages.StartArgs,
  timeout_ms: Int,
) -> Result(agent.AgentRef, ApiCallError(messages.StartError)) {
  safe_call.call_within(manager, timeout_ms, fn(reply_to) {
    messages.StartAgent(args, reply_to)
  })
  |> result.map_error(CallFailed)
  |> result.try(fn(reply) { reply |> result.map_error(ActorError) })
}

pub fn stop_agent(
  manager: process.Subject(messages.AgentManagerMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Nil, ApiCallError(messages.StopError)) {
  safe_call.call_within(manager, timeout_ms, fn(reply_to) {
    messages.StopAgent(instance_id, reply_to)
  })
  |> result.map_error(CallFailed)
  |> result.try(fn(reply) { reply |> result.map_error(ActorError) })
}

pub fn delete_agent(
  manager: process.Subject(messages.AgentManagerMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Nil, ApiCallError(messages.DeleteError)) {
  safe_call.call_within(manager, timeout_ms, fn(reply_to) {
    messages.DeleteAgent(instance_id, reply_to)
  })
  |> result.map_error(CallFailed)
  |> result.try(fn(reply) { reply |> result.map_error(ActorError) })
}

pub fn list_agents(
  manager: process.Subject(messages.AgentManagerMsg),
  timeout_ms: Int,
) -> Result(List(types_agent.InstanceSummary), safe_call.CallError) {
  safe_call.call_within(manager, timeout_ms, fn(reply_to) {
    messages.ListAgents(reply_to)
  })
}
