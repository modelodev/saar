//// TCP listener helpers for port availability checks.
////
//// Mission: provide a small, typed surface over glisten TCP listening.
////
//// Responsibilities:
//// - Parse supported host strings into listen interfaces.
//// - Open/close listeners and surface bind errors.
////
//// Non-responsibilities:
//// - Managing active connections or socket I/O.
//// - Supporting arbitrary host formats beyond the documented set.
////
//// Relationships:
//// - Uses `glisten/tcp` and `glisten/socket/options` for listening.
//// - Consumed by `saar/net/port_check` and integration tests.

import gleam/int
import gleam/result
import gleam/string
import glisten/socket
import glisten/socket/options
import glisten/tcp

/// Handle for a TCP listener socket.
pub type Listener =
  socket.ListenSocket

/// Errors returned while opening a TCP listener.
pub type ListenError {
  /// The address/port tuple is already in use.
  ListenInUse
  /// The host string is not supported by this module.
  ListenInvalidHost(host: String)
  /// The runtime denied permission to bind/listen.
  ListenPermissionDenied
  /// Binding failed for an OS/runtime reason.
  ListenFailed(reason: String)
}

/// Opens a TCP listener for the given host and port.
///
/// Supported hosts: `localhost`, `0.0.0.0`, and IPv4 literals.
///
/// Errors:
/// - `ListenInvalidHost` when the host format is unsupported.
/// - `ListenPermissionDenied` when binding is not permitted.
/// - `ListenInUse` when the address is already in use.
/// - `ListenFailed` for other runtime failures.
///
/// Example:
/// ```gleam
/// import saar/net/tcp_listener
///
/// let assert Ok(#(listener, port)) = tcp_listener.listen("127.0.0.1", 0)
/// tcp_listener.close(listener)
/// port
/// ```
pub fn listen(host: String, port: Int) -> Result(#(Listener, Int), ListenError) {
  use interface <- result.try(parse_interface(host))

  let listen_options = [
    options.Ip(interface),
    options.Reuseaddr(True),
    options.ActiveMode(options.Passive),
  ]

  use listener <- result.try(
    tcp.listen(port, listen_options)
    |> result.map_error(reason_to_listen_error),
  )

  case sockname_port(listener) {
    Ok(actual_port) -> Ok(#(listener, actual_port))
    Error(error) -> {
      let _ = tcp.close(listener)
      Error(error)
    }
  }
}

fn sockname_port(listener: Listener) -> Result(Int, ListenError) {
  tcp.sockname(listener)
  |> result.map(fn(sockname) {
    let #(_, actual_port) = sockname
    actual_port
  })
  |> result.map_error(reason_to_listen_error)
}

/// Closes a TCP listener created with `listen`.
///
/// Example:
/// ```gleam
/// import saar/net/tcp_listener
///
/// let assert Ok(#(listener, _)) = tcp_listener.listen("127.0.0.1", 0)
/// tcp_listener.close(listener)
/// ```
pub fn close(listener: Listener) -> Nil {
  let _ = tcp.close(listener)
  Nil
}

fn parse_interface(host: String) -> Result(options.Interface, ListenError) {
  case host {
    "localhost" -> Ok(options.Address(options.IpV4(127, 0, 0, 1)))
    "0.0.0.0" -> Ok(options.Address(options.IpV4(0, 0, 0, 0)))
    _ ->
      parse_ipv4(host)
      |> result.map(options.Address)
      |> result.map_error(fn(_) { ListenInvalidHost(host: host) })
  }
}

fn parse_ipv4(host: String) -> Result(options.IpAddress, Nil) {
  case string.split(host, ".") {
    [a, b, c, d] -> {
      use a <- result.try(parse_octet(a))
      use b <- result.try(parse_octet(b))
      use c <- result.try(parse_octet(c))
      use d <- result.try(parse_octet(d))
      Ok(options.IpV4(a, b, c, d))
    }
    _ -> Error(Nil)
  }
}

fn parse_octet(value: String) -> Result(Int, Nil) {
  use number <- result.try(int.parse(value))
  case number >= 0 && number <= 255 {
    True -> Ok(number)
    False -> Error(Nil)
  }
}

fn reason_to_listen_error(reason: socket.SocketReason) -> ListenError {
  case reason {
    socket.Eaddrinuse -> ListenInUse
    socket.Eacces -> ListenPermissionDenied
    socket.Eperm -> ListenPermissionDenied
    _ -> ListenFailed(string.inspect(reason))
  }
}
