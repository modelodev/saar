// Extracted reference snippet (v0)
// Purpose: documentation-only; may not compile as-is.
//
// sad/core/port_pool_api.gleam

import gleam/erlang/process.{type Subject}
import sad/core/messages.{type PortPoolMsg, Allocate, Release}
import sad/otp/safe_call
import sad/otp/safe_call.{type CallError}
import sad/port_pool.{type PortPoolError}
import sad/types.{type InstanceId}

pub fn allocate(
  pool: Subject(PortPoolMsg),
  instance_id: InstanceId,
  timeout_ms: Int,
) -> Result(Result(Int, PortPoolError), CallError) {
  safe_call.call_within(pool, timeout_ms, fn(reply_to) {
    Allocate(instance_id, reply_to)
  })
}

pub fn release(
  pool: Subject(PortPoolMsg),
  instance_id: InstanceId,
  timeout_ms: Int,
) -> Result(Nil, CallError) {
  safe_call.call_within(pool, timeout_ms, fn(reply_to) {
    Release(instance_id, reply_to)
  })
}
