////
//// Mission: provide a small, typed API over the `RegistryActor` message protocol.
////
//// Responsibilities:
//// - Encapsulate message construction for callers.
//// - Ensure timeouts are always explicit at call sites.
////
//// Non-responsibilities:
//// - Defining the Registry state machine (see `sad/core/registry`).
//// - Applying default timeouts.
////
//// Relationships:
//// - Uses `sad/otp/safe_call.call_within` for failure-safe boundary calls.
//// - Targets the `sad/core/messages.RegistryMsg` protocol.

import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
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

/// Registers an agent with its initial status.
///
/// The registry enforces global uniqueness by `InstanceId`.
pub fn register(
  registry: process.Subject(messages.RegistryMsg),
  status: types_agent.AgentStatusView,
  agent: agent.AgentRef,
  timeout_ms: Int,
) -> Result(Nil, ApiCallError(messages.RegistryError)) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.Register(status, agent, reply_to)
  })
  |> result.map_error(CallFailed)
  |> result.try(fn(reply) { reply |> result.map_error(ActorError) })
}

/// Unregisters an agent by composite key.
///
/// Fire-and-forget: no confirmation is awaited.
pub fn unregister(
  registry: process.Subject(messages.RegistryMsg),
  key: messages.InstanceKey,
) -> Nil {
  process.send(registry, messages.Unregister(key))
}

/// Unregisters an agent by `InstanceId`.
///
/// Fire-and-forget: no confirmation is awaited.
pub fn unregister_by_instance_id(
  registry: process.Subject(messages.RegistryMsg),
  instance_id: types_core.InstanceId,
) -> Nil {
  process.send(registry, messages.UnregisterByInstanceId(instance_id))
}

/// Looks up an agent by `InstanceKey`.
pub fn lookup(
  registry: process.Subject(messages.RegistryMsg),
  key: messages.InstanceKey,
  timeout_ms: Int,
) -> Result(Option(agent.AgentRef), safe_call.CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.Lookup(key, reply_to)
  })
}

/// Convenience lookup by profile and instance id.
pub fn lookup_by_ids(
  registry: process.Subject(messages.RegistryMsg),
  profile_id: types_core.ProfileId,
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Option(agent.AgentRef), safe_call.CallError) {
  lookup(registry, messages.InstanceKey(profile_id, instance_id), timeout_ms)
}

/// Looks up an agent by `InstanceId`.
pub fn lookup_by_instance_id(
  registry: process.Subject(messages.RegistryMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Option(agent.AgentRef), safe_call.CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.LookupByInstanceId(instance_id, reply_to)
  })
}

/// Lists instance ids registered under a profile.
pub fn list_by_profile(
  registry: process.Subject(messages.RegistryMsg),
  profile_id: types_core.ProfileId,
  timeout_ms: Int,
) -> Result(List(types_core.InstanceId), safe_call.CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.ListByProfile(profile_id, reply_to)
  })
}

/// Lists all registered instance summaries.
pub fn list_all(
  registry: process.Subject(messages.RegistryMsg),
  timeout_ms: Int,
) -> Result(List(types_agent.InstanceSummary), safe_call.CallError) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.ListAll(reply_to)
  })
}

/// Updates the cached status of an instance.
///
/// Fire-and-forget: no confirmation is awaited.
pub fn update_status(
  registry: process.Subject(messages.RegistryMsg),
  instance_id: types_core.InstanceId,
  status: types_agent.AgentStatusView,
) -> Nil {
  process.send(registry, messages.UpdateStatus(instance_id, status))
}

/// Counts the number of registered instances.
pub fn count(
  registry: process.Subject(messages.RegistryMsg),
  timeout_ms: Int,
) -> Result(Int, safe_call.CallError) {
  case list_all(registry, timeout_ms) {
    Ok(items) -> Ok(list.length(items))
    Error(err) -> Error(err)
  }
}
