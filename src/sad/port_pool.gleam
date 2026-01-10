//// Managed port pool.
////
//// Mission: allocate and reserve ports in a configured range, keyed by
//// `InstanceId`, and optionally validate that a port can be bound.
////
//// Responsibilities:
//// - Maintain port reservations per instance.
//// - Allocate the next available port in a range.
//// - Optionally check host bind availability via a callback.
////
//// Non-responsibilities:
//// - Performing OS-level checks directly (callers supply `check`).
//// - Managing TCP listeners or network I/O.
////
//// Relationships:
//// - Used by `sad/net/port_check` and `sad/port_pool/checked`.
//// - Integrates with instance identity via `sad/types/core.InstanceId`.
////
//// Contract notes:
//// - Allocation order is not guaranteed; callers must not rely on "lowest free port".
//// - The pool may keep an internal cursor to reduce repeated scans under contention.

import gleam/dict
import sad/types/core as types_core

/// Errors that can occur when allocating from a port pool.
pub type PortPoolError {
  /// The configured min/max port range is invalid.
  InvalidRange
  /// All ports in the range are reserved.
  PoolExhausted
  /// No candidate port became usable after at least one "in use" result.
  ///
  /// This can happen when all candidates are occupied, or due to a race between a
  /// successful availability check and a later bind/use step (see `sad/port_pool/checked`).
  PortInUse
  /// The bind check failed with a runtime reason.
  BindCheckFailed(reason: String)
  /// No checked port became available after retries.
  NoAvailablePortAfterRetries(attempts: Int)
}

/// Result of checking if a port can be bound on the host.
///
/// This is intended to be produced by higher-level code (e.g. `sad/net/port_check`).
pub type PortCheckError {
  /// The port is in use.
  CheckPortInUse
  /// Binding failed for an OS/runtime reason.
  CheckBindFailed(reason: String)
}

/// Pool state and reservations.
///
/// The pool keeps two indexes:
/// - `reserved_by_instance`: instance -> port
/// - `reserved_ports`: port -> instance
///
/// The second index makes checking whether a port is reserved O(1).
///
/// It also keeps `next_port`, an internal cursor used to reduce repeated scans
/// when allocating under contention.
pub type PortPool {
  PortPool(
    min_port: Int,
    max_port: Int,
    next_port: Int,
    reserved_by_instance: dict.Dict(types_core.InstanceId, Int),
    reserved_ports: dict.Dict(Int, types_core.InstanceId),
  )
}

type PortRange {
  PortRange(min_port: Int, max_port: Int)
}

/// Creates a new pool for the given inclusive port range.
///
/// Example:
/// ```gleam
/// import sad/port_pool
///
/// port_pool.init(9000, 9010)
/// ```
pub fn init(min_port: Int, max_port: Int) -> Result(PortPool, PortPoolError) {
  case validate_range(min_port, max_port) {
    Ok(PortRange(min_port: min_port, max_port: max_port)) ->
      Ok(PortPool(min_port, max_port, min_port, dict.new(), dict.new()))

    Error(err) -> Error(err)
  }
}

fn validate_range(
  min_port: Int,
  max_port: Int,
) -> Result(PortRange, PortPoolError) {
  case min_port > 0 && max_port >= min_port {
    True -> Ok(PortRange(min_port: min_port, max_port: max_port))
    False -> Error(InvalidRange)
  }
}

/// Allocates a port for an instance without performing any bind checks.
///
/// If the instance already has a reservation, returns the same port.
///
/// Note: allocation order is not specified.
///
/// Prefer `sad/port_pool/checked` when you need host-level checks.
pub fn allocate(
  pool: PortPool,
  instance_id: types_core.InstanceId,
) -> Result(#(PortPool, Int), PortPoolError) {
  allocate_checked(pool, instance_id, fn(_port) { Ok(Nil) })
}

/// Allocates a port only if the `check` confirms it can be bound.
///
/// This is a low-level primitive: callers provide `check` to avoid introducing
/// I/O dependencies into this module. For the default host check and race-safe
/// claiming, prefer `sad/port_pool/checked`.
///
/// Note: allocation order is not specified.
///
/// If the instance already has a reservation, returns the same port without
/// re-running `check`.
pub fn allocate_checked(
  pool: PortPool,
  instance_id: types_core.InstanceId,
  check: fn(Int) -> Result(Nil, PortCheckError),
) -> Result(#(PortPool, Int), PortPoolError) {
  let PortPool(
    min_port,
    max_port,
    next_port,
    reserved_by_instance,
    reserved_ports,
  ) = pool

  case dict.get(reserved_by_instance, instance_id) {
    Ok(port) -> Ok(#(pool, port))
    Error(_) -> {
      let range_size = max_port - min_port + 1

      case
        find_checked_port(
          next_port,
          min_port,
          max_port,
          reserved_ports,
          check,
          range_size,
          0,
        )
      {
        Ok(port) -> Ok(#(reserve(pool, instance_id, port), port))
        Error(err) -> Error(err)
      }
    }
  }
}

/// Releases a reservation for the given instance.
pub fn release(pool: PortPool, instance_id: types_core.InstanceId) -> PortPool {
  let PortPool(
    min_port,
    max_port,
    next_port,
    reserved_by_instance,
    reserved_ports,
  ) = pool

  case dict.get(reserved_by_instance, instance_id) {
    Ok(port) -> {
      let next_by_instance = dict.delete(reserved_by_instance, instance_id)
      let next_ports = dict.delete(reserved_ports, port)
      PortPool(min_port, max_port, next_port, next_by_instance, next_ports)
    }
    Error(_) -> pool
  }
}

fn reserve(
  pool: PortPool,
  instance_id: types_core.InstanceId,
  port: Int,
) -> PortPool {
  let PortPool(
    min_port,
    max_port,
    _next_port,
    reserved_by_instance,
    reserved_ports,
  ) = pool

  let next_by_instance = dict.insert(reserved_by_instance, instance_id, port)
  let next_ports = dict.insert(reserved_ports, port, instance_id)
  let next_port = wrap_port(port + 1, min_port, max_port)

  PortPool(min_port, max_port, next_port, next_by_instance, next_ports)
}

fn wrap_port(port: Int, min_port: Int, max_port: Int) -> Int {
  case port > max_port {
    True -> min_port
    False -> port
  }
}

fn find_checked_port(
  current: Int,
  min_port: Int,
  max_port: Int,
  reserved_ports: dict.Dict(Int, types_core.InstanceId),
  check: fn(Int) -> Result(Nil, PortCheckError),
  remaining: Int,
  attempts: Int,
) -> Result(Int, PortPoolError) {
  case remaining <= 0 {
    True -> Error(exhausted_checked_error(attempts))
    False ->
      case dict.has_key(reserved_ports, current) {
        True ->
          find_checked_port(
            wrap_port(current + 1, min_port, max_port),
            min_port,
            max_port,
            reserved_ports,
            check,
            remaining - 1,
            attempts,
          )

        False ->
          case check(current) {
            Ok(_) -> Ok(current)
            Error(CheckPortInUse) ->
              find_checked_port(
                wrap_port(current + 1, min_port, max_port),
                min_port,
                max_port,
                reserved_ports,
                check,
                remaining - 1,
                attempts + 1,
              )
            Error(CheckBindFailed(reason)) -> Error(BindCheckFailed(reason))
          }
      }
  }
}

fn exhausted_checked_error(attempts: Int) -> PortPoolError {
  case attempts {
    0 -> PoolExhausted
    1 -> PortInUse
    _ -> NoAvailablePortAfterRetries(attempts)
  }
}
