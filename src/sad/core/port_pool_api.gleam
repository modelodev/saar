////
//// Mission: provide a typed API for interacting with the `PortPoolActor`.
////
//// Responsibilities:
//// - Encapsulate message construction.
//// - Expose `allocate_checked` for host bind validation.
////
//// Non-responsibilities:
//// - Owning the pool state (that is `PortPoolActor`).
//// - Managing TCP listeners or long-lived sockets.
////
//// Relationships:
//// - Targets `sad/core/messages.PortPoolMsg`.
//// - Uses `sad/otp/safe_call.call_within` for safe boundary calls.

import gleam/erlang/process
import sad/core/messages
import sad/otp/safe_call
import sad/port_pool
import sad/types/core as types_core

/// Allocates a port (best-effort; no OS bind check).
pub fn allocate(
  pool: process.Subject(messages.PortPoolMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Result(Int, port_pool.PortPoolError), safe_call.CallError) {
  safe_call.call_within(pool, timeout_ms, fn(reply_to) {
    messages.Allocate(instance_id, reply_to)
  })
}

/// Releases a reserved port (idempotent).
pub fn release(
  pool: process.Subject(messages.PortPoolMsg),
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Nil, safe_call.CallError) {
  safe_call.call_within(pool, timeout_ms, fn(reply_to) {
    messages.Release(instance_id, reply_to)
  })
}

/// Allocates a port and validates it can be bound on `host`.
///
/// Port selection order is not guaranteed.
pub fn allocate_checked(
  pool: process.Subject(messages.PortPoolMsg),
  host: String,
  instance_id: types_core.InstanceId,
  timeout_ms: Int,
) -> Result(Result(Int, port_pool.PortPoolError), safe_call.CallError) {
  safe_call.call_within(pool, timeout_ms, fn(reply_to) {
    messages.AllocateChecked(host, instance_id, reply_to)
  })
}
