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
//// - Consumed by `sad/net/port_check` and integration tests.

import gleam/int
import gleam/result
import gleam/string
import glisten/socket as socket
import glisten/socket/options as options
import glisten/tcp

/// Handle for a TCP listener socket.
pub type Listener =
  socket.ListenSocket

/// Errors returned while opening a TCP listener.
pub type ListenError {
  /// The address/port tuple is already in use.
  ListenInUse
  /// Binding failed for an OS/runtime reason or invalid host.
  ListenFailed(reason: String)
}

/// Opens a TCP listener for the given host and port.
///
/// Supported hosts: `localhost`, `0.0.0.0`, and IPv4 literals.
///
/// Example:
/// ```gleam
/// import sad/net/tcp_listener
///
/// let assert Ok(#(listener, port)) = tcp_listener.listen("127.0.0.1", 0)
/// tcp_listener.close(listener)
/// port
/// ```
pub fn listen(host: String, port: Int) -> Result(#(Listener, Int), ListenError) {
  use interface <- result.try(parse_interface(host))

  let options = [
    options.Ip(interface),
    options.Reuseaddr(True),
    options.ActiveMode(options.Passive),
  ]

  case tcp.listen(port, options) {
    Ok(listener) ->
      case tcp.sockname(listener) {
        Ok(#(_, actual_port)) -> Ok(#(listener, actual_port))
        Error(reason) -> {
          let _ = tcp.close(listener)
          Error(reason_to_listen_error(reason))
        }
      }
    Error(reason) -> Error(reason_to_listen_error(reason))
  }
}

/// Closes a TCP listener created with `listen`.
///
/// Example:
/// ```gleam
/// import sad/net/tcp_listener
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
    "localhost" -> Ok(options.Loopback)
    "0.0.0.0" -> Ok(options.Any)
    _ ->
      case parse_ipv4(host) {
        Ok(address) -> Ok(options.Address(address))
        Error(_) ->
          Error(ListenFailed("Unsupported host: " <> host))
      }
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
    _ -> ListenFailed(string.inspect(reason))
  }
}
