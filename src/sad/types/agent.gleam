////
//// Mission: define stable, serializable agent and instance "view" types.
////
//// Responsibilities:
//// - Provide `AgentStatusView` and `InstanceSummary` for core actors and gateways.
//// - Keep the types small and safe to expose at the boundary.
////
//// Non-responsibilities:
//// - Carrying OTP handles (Subjects, Pids, monitors).
//// - Performing IO or state management.
////
//// Relationships:
//// - Consumed by core OTP actors (registry, manager) and by the HTTP gateway.
//// - Depends only on domain primitives from `sad/types/core` and `sad/types/enums`.

import gleam/option.{type Option}
import sad/types/core as types_core
import sad/types/enums as types_enums

/// Coarse phase of an agent instance.
///
/// This is intended to be stable for clients.
pub type AgentPhase {
  Created
  Provisioning
  ReadyTransient
  ReadyContinuous
  Stopped
  Failed
}

/// Coarse execution mode of an agent.
///
/// This is a high-level, safe-to-expose view derived from internal actor state.
pub type AgentRunMode {
  RunIdle
  RunBusy
}

/// Public, serializable view of an agent instance state.
///
/// This value is safe to log and to expose via HTTP.
pub type AgentStatusView {
  AgentStatusView(
    profile_id: types_core.ProfileId,
    instance_id: types_core.InstanceId,
    lifecycle: types_enums.Lifecycle,
    phase: AgentPhase,
    mode: AgentRunMode,
    assigned_port: Option(Int),
    failure_reason: Option(String),
  )
}

/// Cached summary of an instance, suitable for list endpoints.
///
/// `registered_at` and `status_updated_at` are in milliseconds.
pub type InstanceSummary {
  InstanceSummary(
    status: AgentStatusView,
    registered_at: Int,
    status_updated_at: Int,
  )
}
