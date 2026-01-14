//// Port availability checks for the managed port pool.
////
//// Mission: determine whether a TCP port can be bound on a host.
////
//// Responsibilities:
//// - Expose a small check function for `port_pool`.
////
//// Non-responsibilities:
//// - Managing reservations or pool state.
////
//// Relationships:
//// - Uses `sad/net/tcp_listener` for bind attempts.
//// - Maps listen failures to `sad/port_pool.PortCheckError`.

import sad/ffi
import sad/port_pool

/// Checks whether `host:port` can be bound.
///
/// This function is a small helper for `sad/port_pool`; it tries to bind a TCP
/// listener and immediately closes it on success.
///
/// Supported hosts: `localhost`, `0.0.0.0`, and IPv4 literals.
///
/// Errors:
/// - `CheckPortInUse` when the port is already in use.
/// - `CheckInvalidHost` when the host format is unsupported.
/// - `CheckPermissionDenied` when binding is not permitted.
/// - `CheckBindFailed` for other bind/listen failures.
///
/// Example:
/// ```gleam
/// import sad/net/port_check
///
/// port_check.check_available("127.0.0.1", 8080)
/// ```
pub fn check_available(
  host: String,
  port: Int,
) -> Result(Nil, port_pool.PortCheckError) {
  case ffi.check_port_available(host, port) {
    Ok(_) -> Ok(Nil)

    Error("in_use") -> Error(port_pool.CheckPortInUse)
    Error("invalid_host") -> Error(port_pool.CheckInvalidHost(host: host))
    Error("permission_denied") -> Error(port_pool.CheckPermissionDenied)
    Error(reason) -> Error(port_pool.CheckBindFailed(reason))
  }
}
