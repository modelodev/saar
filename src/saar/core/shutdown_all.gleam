//// Core shutdown helpers.
////
//// Mission: provide best-effort helpers for shutting down all running agents.
////
//// Responsibilities:
//// - List running instances via the RegistryActor.
//// - Send `AgentActor.terminate(NodeShuttingDown)` to each instance.
////
//// Non-responsibilities:
//// - Waiting for termination completion (owned by higher-level shutdown flows).
//// - Forcing the VM to exit.
////
//// Relationships:
//// - Used by `saar/gateway/shutdown` during graceful shutdown.

import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import saar/core/agent
import saar/core/messages
import saar/otp/safe_call
import saar/types/agent as types_agent
import saar/types/core as types_core

/// Sends `Terminate(NodeShuttingDown)` to all currently registered agents.
///
/// This is best-effort: listing failures or missing agents are ignored.
pub fn send_terminate_to_all(
  registry: process.Subject(messages.RegistryMsg),
  timeout_ms: Int,
) -> Nil {
  let summaries = list_instances(registry, timeout_ms)

  summaries
  |> list.each(fn(summary) {
    let instance_id = instance_id_from_summary(summary)

    case lookup_agent(registry, instance_id, timeout_ms) {
      Some(agent_ref) -> agent.terminate(agent_ref, agent.NodeShuttingDown)
      _ -> Nil
    }
  })

  Nil
}

/// Returns `True` if all registry entries are stopped.
///
/// The registry keeps stopped instances for diagnostics; during shutdown we
/// consider the system drained once every instance phase is `Stopped` or `Failed`.
/// Listing failures are treated as drained (best-effort shutdown).
pub fn all_instances_stopped(
  registry: process.Subject(messages.RegistryMsg),
  timeout_ms: Int,
) -> Bool {
  list_instances(registry, timeout_ms)
  |> list.all(fn(summary) {
    let types_agent.InstanceSummary(status: status, ..) = summary
    let types_agent.AgentStatusView(phase: phase, ..) = status

    case phase {
      types_agent.Stopped | types_agent.Failed(_) -> True
      _ -> False
    }
  })
}

fn list_instances(
  registry: process.Subject(messages.RegistryMsg),
  timeout_ms: Int,
) -> List(types_agent.InstanceSummary) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.ListAll(reply_to)
  })
  |> result.unwrap([])
}

fn lookup_agent(
  registry: process.Subject(messages.RegistryMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Option(agent.AgentRef) {
  safe_call.call_within(registry, timeout_ms, fn(reply_to) {
    messages.LookupByInstanceId(instance_id, reply_to)
  })
  |> result.unwrap(None)
}

fn instance_id_from_summary(
  summary: types_agent.InstanceSummary,
) -> types_core.InstanceId {
  let types_agent.InstanceSummary(status: status, ..) = summary
  let types_agent.AgentStatusView(instance_id: instance_id, ..) = status
  instance_id
}
