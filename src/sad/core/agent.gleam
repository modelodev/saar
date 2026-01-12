////
//// Mission: provide the stable, public handle to an AgentActor.
////
//// Responsibilities:
//// - Define the opaque `AgentRef` type used by other core actors.
//// - Provide minimal helpers needed by other core components (e.g. pid discovery).
////
//// Non-responsibilities:
//// - Implementing the AgentActor message loop (introduced in later sprints).
//// - Performing any IO or runner orchestration.
////
//// Relationships:
//// - `sad/core/registry` monitors agents via `pid`.
//// - Future sprints will replace this module with the real AgentActor + API.

import gleam/erlang/process.{type Pid}

/// Opaque handle to an agent process.
///
/// In v0 this handle is intentionally minimal: it carries only the owning `Pid`
/// so other core components can monitor it.
///
/// Future sprints will replace this module with the real AgentActor + public API.
pub opaque type AgentRef {
  AgentRef(pid: Pid)
}

/// Builds an `AgentRef` from a process id.
///
/// This is intended for internal wiring and unit tests.
pub fn unsafe_from_pid(pid: Pid) -> AgentRef {
  AgentRef(pid: pid)
}

/// Returns the pid associated with an agent.
pub fn pid(agent: AgentRef) -> Pid {
  let AgentRef(pid: pid) = agent
  pid
}
