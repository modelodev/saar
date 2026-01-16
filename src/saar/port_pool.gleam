//// Managed port pool.
////
//// Mission: allocate and reserve ports in a configured range, keyed by
//// `InstanceId`, and optionally validate that a port can be bound.
////
//// Responsibilities:
//// - Maintain port reservations per instance.
//// - Allocate the next available port in a range.
//// - Optionally check host bind availability via a callback.
//// - Provide allocation metadata for safe release+retry orchestration.
////
//// Non-responsibilities:
//// - Performing OS-level checks directly (callers supply `check`).
//// - Managing TCP listeners or network I/O.
////
//// Relationships:
//// - Used by `saar/net/port_check` and `saar/port_pool/checked`.
//// - Integrates with instance identity via `saar/types/core.InstanceId`.
////
//// Contract notes:
//// - Allocation order is not guaranteed; callers must not rely on "lowest free port".
//// - The pool may keep an internal cursor to reduce repeated scans under contention.

import gleam/dict
import gleam/result
import saar/types/core as types_core

/// Errors that can occur when allocating from a port pool.
pub type PortPoolError {
  /// The configured min/max port range is invalid.
  InvalidRange
  /// All ports in the range are reserved.
  PoolExhausted
  /// No candidate port became usable after at least one "in use" result.
  ///
  /// This can happen when all candidates are occupied, or due to a race between a
  /// successful availability check and a later bind/use step (see `saar/port_pool/checked`).
  PortInUse
  /// The host format is unsupported by the bind checker.
  BindCheckInvalidHost(host: String)
  /// Binding was not permitted by the runtime.
  BindCheckPermissionDenied
  /// The bind check failed with a runtime reason.
  BindCheckFailed(reason: String)
  /// No checked port became available after retries.
  NoAvailablePortAfterRetries(attempts: Int)
}

/// Result of checking if a port can be bound on the host.
///
/// This is intended to be produced by higher-level code (e.g. `saar/net/port_check`).
pub type PortCheckError {
  /// The port is in use.
  CheckPortInUse
  /// The host format is unsupported.
  CheckInvalidHost(host: String)
  /// Binding was not permitted by the runtime.
  CheckPermissionDenied
  /// Binding failed for an OS/runtime reason.
  CheckBindFailed(reason: String)
}

/// Indicates whether an allocation reused an existing reservation.
///
/// This is useful for higher-level orchestration that wants to safely release and
/// retry only when a reservation was created as part of the current operation.
pub type AllocationSource {
  /// The instance already had a reservation.
  ExistingReservation
  /// A new reservation was created.
  NewReservation
}

/// Maps a bind-check error into a pool-level error.
///
/// Example:
/// ```gleam
/// import saar/port_pool
///
/// port_pool.port_check_error_to_pool_error(port_pool.CheckPermissionDenied)
/// ```
pub fn port_check_error_to_pool_error(err: PortCheckError) -> PortPoolError {
  case err {
    CheckPortInUse -> PortInUse
    CheckInvalidHost(host: host) -> BindCheckInvalidHost(host: host)
    CheckPermissionDenied -> BindCheckPermissionDenied
    CheckBindFailed(reason) -> BindCheckFailed(reason)
  }
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
/// import saar/port_pool
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
/// Prefer `saar/port_pool/checked` when you need host-level checks.
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
/// claiming, prefer `saar/port_pool/checked`.
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
  use #(next_pool, port, _) <- result.try(allocate_checked_with_source(
    pool,
    instance_id,
    check,
  ))
  Ok(#(next_pool, port))
}

/// Allocates a port like `allocate_checked`, also returning how it was obtained.
///
/// This is useful for higher-level orchestration that needs to know whether it
/// may safely release and retry after a later "use" step fails.
///
/// If the instance already has a reservation, this returns `ExistingReservation`
/// and does not re-run `check`.
pub fn allocate_checked_with_source(
  pool: PortPool,
  instance_id: types_core.InstanceId,
  check: fn(Int) -> Result(Nil, PortCheckError),
) -> Result(#(PortPool, Int, AllocationSource), PortPoolError) {
  let PortPool(
    min_port,
    max_port,
    next_port,
    reserved_by_instance,
    reserved_ports,
  ) = pool

  case dict.get(reserved_by_instance, instance_id) {
    Ok(port) -> Ok(#(pool, port, ExistingReservation))
    Error(_) -> {
      let range_size = max_port - min_port + 1

      use port <- result.try(find_checked_port(
        next_port,
        min_port,
        max_port,
        reserved_ports,
        check,
        range_size,
        0,
      ))

      Ok(#(reserve(pool, instance_id, port), port, NewReservation))
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
      find_checked_port_unreserved(
        current,
        min_port,
        max_port,
        reserved_ports,
        check,
        remaining,
        attempts,
      )
  }
}

fn find_checked_port_unreserved(
  current: Int,
  min_port: Int,
  max_port: Int,
  reserved_ports: dict.Dict(Int, types_core.InstanceId),
  check: fn(Int) -> Result(Nil, PortCheckError),
  remaining: Int,
  attempts: Int,
) -> Result(Int, PortPoolError) {
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
      find_checked_port_checked(
        current,
        min_port,
        max_port,
        reserved_ports,
        check,
        remaining,
        attempts,
      )
  }
}

fn find_checked_port_checked(
  current: Int,
  min_port: Int,
  max_port: Int,
  reserved_ports: dict.Dict(Int, types_core.InstanceId),
  check: fn(Int) -> Result(Nil, PortCheckError),
  remaining: Int,
  attempts: Int,
) -> Result(Int, PortPoolError) {
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

    Error(err) -> Error(port_check_error_to_pool_error(err))
  }
}

fn exhausted_checked_error(attempts: Int) -> PortPoolError {
  case attempts {
    0 -> PoolExhausted
    1 -> PortInUse
    _ -> NoAvailablePortAfterRetries(attempts)
  }
}
