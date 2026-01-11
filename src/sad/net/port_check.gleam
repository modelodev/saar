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

import sad/net/tcp_listener
import sad/port_pool

/// Checks whether `host:port` can be bound.
///
/// This function is a small helper for `sad/port_pool`; it tries to listen on
/// the given address and immediately closes the listener on success.
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
  case tcp_listener.listen(host, port) {
    Ok(#(listener, _)) -> {
      tcp_listener.close(listener)
      Ok(Nil)
    }
    Error(tcp_listener.ListenInUse) -> Error(port_pool.CheckPortInUse)
    Error(tcp_listener.ListenInvalidHost(host: host)) ->
      Error(port_pool.CheckInvalidHost(host: host))
    Error(tcp_listener.ListenPermissionDenied) ->
      Error(port_pool.CheckPermissionDenied)
    Error(tcp_listener.ListenFailed(reason)) ->
      Error(port_pool.CheckBindFailed(reason))
  }
}
