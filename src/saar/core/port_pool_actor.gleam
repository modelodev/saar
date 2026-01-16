////
//// Mission: keep the SSOT of managed port reservations in memory.
////
//// Responsibilities:
//// - Hold a `saar/port_pool.PortPool` state inside an OTP actor.
//// - Allocate and reserve ports per `InstanceId`.
//// - Allocate ports after validating bind availability on a host.
//// - Release reservations idempotently.
////
//// Non-responsibilities:
//// - Managing TCP listeners or long-lived sockets.
////
//// Relationships:
//// - Message protocol lives in `saar/core/messages.PortPoolMsg`.
//// - Boundary callers should use `saar/otp/safe_call` with `saar/core/messages.PortPoolMsg`.

import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import saar/core/messages
import saar/port_pool
import saar/port_pool/checked as port_pool_checked

pub fn start(
  name: process.Name(messages.PortPoolMsg),
  min_port: Int,
  max_port: Int,
) -> actor.StartResult(process.Subject(messages.PortPoolMsg)) {
  let init = fn(self) {
    case port_pool.init(min_port, max_port) {
      Error(err) -> Error("port_pool_init_failed:" <> port_pool_error_code(err))
      Ok(pool) -> actor.initialised(pool) |> actor.returning(self) |> Ok
    }
  }

  actor.new_with_initialiser(5000, init)
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  pool: port_pool.PortPool,
  msg: messages.PortPoolMsg,
) -> actor.Next(port_pool.PortPool, messages.PortPoolMsg) {
  case msg {
    messages.Allocate(instance_id, reply_to) ->
      case port_pool.allocate(pool, instance_id) {
        Ok(#(next_pool, port)) -> {
          process.send(reply_to, Ok(port))
          actor.continue(next_pool)
        }

        Error(err) -> {
          process.send(reply_to, Error(err))
          actor.continue(pool)
        }
      }

    messages.AllocateChecked(host, instance_id, reply_to) ->
      case port_pool_checked.allocate_checked_on_host(pool, instance_id, host) {
        Ok(#(next_pool, port)) -> {
          process.send(reply_to, Ok(port))
          actor.continue(next_pool)
        }

        Error(err) -> {
          process.send(reply_to, Error(err))
          actor.continue(pool)
        }
      }

    messages.Release(instance_id, reply_to) -> {
      process.send(reply_to, Nil)
      actor.continue(port_pool.release(pool, instance_id))
    }
  }
}

fn port_pool_error_code(err: port_pool.PortPoolError) -> String {
  case err {
    port_pool.InvalidRange -> "invalid_range"
    port_pool.PoolExhausted -> "pool_exhausted"
    port_pool.PortInUse -> "port_in_use"
    port_pool.BindCheckInvalidHost(host: host) -> "invalid_host:" <> host
    port_pool.BindCheckPermissionDenied -> "permission_denied"
    port_pool.BindCheckFailed(reason) -> "bind_failed:" <> reason
    port_pool.NoAvailablePortAfterRetries(attempts: attempts) ->
      "no_port_after:" <> int.to_string(attempts)
  }
}
