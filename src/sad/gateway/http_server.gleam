////
//// Mission: placeholder HTTP server for the core OTP skeleton.
////
//// Responsibilities:
//// - Exist as the last child in the RootSupervisor start order.
//// - Stay alive so the supervision tree remains stable.
////
//// Non-responsibilities:
//// - Implementing any real HTTP gateway (introduced in later sprints).
//// - Owning or mutating core state.
////
//// Relationships:
//// - Started by `sad/core/root_supervisor` as the last RestForOne child.

import gleam/erlang/process
import gleam/otp/actor
import sad/core/messages
import sad/types/config as types_config

pub fn start(
  _config: types_config.SadConfig,
  _agent_manager: process.Subject(messages.AgentManagerMsg),
) -> actor.StartResult(Nil) {
  let pid = process.spawn(fn() { process.sleep_forever() })
  Ok(actor.Started(pid: pid, data: Nil))
}
