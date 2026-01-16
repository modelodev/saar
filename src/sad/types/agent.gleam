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
import sad/types/profile as types_profile
import sad/types/runner as types_runner

/// Coarse phase of an agent instance.
///
/// This is intended to be stable for clients.
///
/// `Failed` carries the stable failure reason.
pub type AgentPhase {
  Created
  Provisioning
  ReadyTransient
  ReadyContinuous
  Stopped
  Failed(FailureReason)
}

/// Coarse execution mode of an agent.
///
/// This is a high-level, safe-to-expose view derived from internal actor state.
pub type AgentRunMode {
  RunIdle
  RunBusy
}

/// Categorical failure reason for an instance.
///
/// This value is safe to expose to clients.
pub type FailureReason {
  PortInUse
  PortBindFailed
  PortPoolExhausted
  StartServerFailed
  StartSnapshotFailed
  ServerDied
  AgentDown
  NoNetwork
  LandlockUnavailable
  Unknown
}

/// Returns a stable, client-facing string for a failure reason.
///
/// This is used by boundary encoders (e.g. HTTP JSON).
pub fn failure_reason_to_string(reason: FailureReason) -> String {
  case reason {
    PortInUse -> "port_in_use"
    PortBindFailed -> "port_bind_failed"
    PortPoolExhausted -> "port_pool_exhausted"
    StartServerFailed -> "start_server_failed"
    StartSnapshotFailed -> "start_snapshot_failed"
    ServerDied -> "server_died"
    AgentDown -> "agent_down"
    NoNetwork -> "no_network"
    LandlockUnavailable -> "landlock_unavailable"
    Unknown -> "unknown"
  }
}

/// Extracts the failure reason from an agent phase, if any.
///
/// Example:
/// ```gleam
/// import gleam/option
/// import sad/types/agent as types_agent
///
/// types_agent.failure_reason_from_phase(types_agent.Failed(types_agent.NoNetwork))
/// // -> option.Some(types_agent.NoNetwork)
/// ```
pub fn failure_reason_from_phase(phase: AgentPhase) -> Option(FailureReason) {
  case phase {
    Failed(reason) -> option.Some(reason)
    _ -> option.None
  }
}

/// Public, serializable view of an agent instance state.
///
/// This value is safe to log and to expose via HTTP.
///
/// When the phase is `Failed`, it carries the failure reason.
pub type AgentStatusView {
  AgentStatusView(
    profile_id: types_core.ProfileId,
    instance_id: types_core.InstanceId,
    lifecycle: types_enums.Lifecycle,
    phase: AgentPhase,
    mode: AgentRunMode,
    assigned_port: Option(Int),
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

/// Public diagnostic information about an agent instance.
///
/// This view is safe to log and to expose via HTTP.
pub type AgentInfoView {
  AgentInfoView(
    meta: types_profile.ProfileMeta,
    runner: types_runner.Runner,
    interface: types_profile.Interface,
    status: AgentStatusView,
  )
}
