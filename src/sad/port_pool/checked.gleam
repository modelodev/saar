//// Checked port allocation helpers.
////
//// Mission: build on `sad/port_pool` to perform host-level availability checks
//// and safely claim a port, handling races.
////
//// Responsibilities:
//// - Compose `port_pool.allocate_checked/3` with a second "use" step that can
////   fail if a race occurs between check and bind.
//// - Provide convenience wrappers that use `sad/net/port_check`.
////
//// Non-responsibilities:
//// - Maintaining pool state; `sad/port_pool` owns reservations.
//// - Implementing TCP checks; delegated to `sad/net/port_check`.
////
//// Relationships:
//// - Depends on `sad/port_pool` for state + error types.
//// - Uses `sad/net/port_check` for host availability checks.

import gleam/result
import sad/net/port_check
import sad/port_pool
import sad/types/core as types_core

/// Allocates a port, checks it, and then attempts to use it.
///
/// This function is meant to handle the race where a port becomes unavailable
/// between a successful check and the actual bind performed by `use_port`.
///
/// Example:
/// ```gleam
/// import sad/port_pool
/// import sad/port_pool/checked as port_pool_checked
///
/// let assert Ok(pool0) = port_pool.init(9000, 9001)
/// // `check` and `use_port` can be the same function if desired.
/// port_pool_checked.allocate_checked_with(
///   pool0,
///   instance_id,
///   fn(_port) { Ok(Nil) },
///   fn(port) { Ok(port) },
/// )
/// ```
pub fn allocate_checked_with(
  pool: port_pool.PortPool,
  instance_id: types_core.InstanceId,
  check: fn(Int) -> Result(Nil, port_pool.PortCheckError),
  use_port: fn(Int) -> Result(a, port_pool.PortCheckError),
) -> Result(#(port_pool.PortPool, a), port_pool.PortPoolError) {
  use #(next_pool, port) <- result.try(port_pool.allocate_checked(
    pool,
    instance_id,
    check,
  ))

  case use_port(port) {
    Ok(value) -> Ok(#(next_pool, value))
    Error(port_pool.CheckPortInUse) -> Error(port_pool.PortInUse)
    Error(port_pool.CheckBindFailed(reason)) ->
      Error(port_pool.BindCheckFailed(reason))
  }
}

/// Allocates a port after checking that it can be bound on `host`.
///
/// Example:
/// ```gleam
/// import sad/port_pool
/// import sad/port_pool/checked as port_pool_checked
///
/// let assert Ok(pool0) = port_pool.init(9000, 9001)
/// port_pool_checked.allocate_checked_on_host(pool0, instance_id, "127.0.0.1")
/// ```
pub fn allocate_checked_on_host(
  pool: port_pool.PortPool,
  instance_id: types_core.InstanceId,
  host: String,
) -> Result(#(port_pool.PortPool, Int), port_pool.PortPoolError) {
  allocate_checked_with(
    pool,
    instance_id,
    fn(port) { port_check.check_available(host, port) },
    fn(port) { Ok(port) },
  )
}

/// Allocates a port after checking availability on `host`, then calls `use_port`.
///
/// Example:
/// ```gleam
/// import sad/port_pool
/// import sad/port_pool/checked as port_pool_checked
///
/// let assert Ok(pool0) = port_pool.init(9000, 9001)
/// port_pool_checked.allocate_checked_and_use_on_host(
///   pool0,
///   instance_id,
///   "127.0.0.1",
///   fn(port) { Ok(port) },
/// )
/// ```
pub fn allocate_checked_and_use_on_host(
  pool: port_pool.PortPool,
  instance_id: types_core.InstanceId,
  host: String,
  use_port: fn(Int) -> Result(a, port_pool.PortCheckError),
) -> Result(#(port_pool.PortPool, a), port_pool.PortPoolError) {
  allocate_checked_with(
    pool,
    instance_id,
    fn(port) { port_check.check_available(host, port) },
    use_port,
  )
}
