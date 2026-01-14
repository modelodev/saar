//// Erlang FFI boundary for SAD.
////
//// Mission: provide a small, typed surface over Erlang functions implemented
//// in the `sad_ffi` Erlang module.
////
//// Responsibilities:
//// - Declare `@external` functions and expose stable, typed wrappers.
//// - Keep port/time interop details localized.
////
//// Non-responsibilities:
//// - Implementing the Erlang side (`sad_ffi`); this module only declares the
////   boundary.
//// - Higher-level runner logic; callers should handle retries, timeouts, etc.
////
//// Relationships:
//// - Uses `gleam/erlang/port.Port` as the port handle type.
//// - All `@external(erlang, "sad_ffi", ...)` functions must match the Erlang
////   function signatures exactly.

import gleam/erlang/port.{type Port}

/// Messages returned by `port_receive`.
///
/// This is a typed representation of the messages emitted by the Erlang port
/// wrapper in `sad_ffi`.
pub type PortMessage {
  /// A chunk of data received from the port.
  PortDataChunk(String)
  /// The port exited with the given exit code.
  PortExit(Int)
}

/// Returns the current monotonic time in milliseconds.
///
/// This is implemented in Erlang (`sad_ffi:now_ms/0`).
///
/// Example:
/// ```gleam
/// import sad/ffi
///
/// let t0 = ffi.now_ms()
/// let t1 = ffi.now_ms()
/// t1 >= t0
/// ```
pub fn now_ms() -> Int {
  now_ms_ffi()
}

@external(erlang, "sad_ffi", "now_ms")
fn now_ms_ffi() -> Int

/// Opens an Erlang port running a command.
///
/// Output chunking is controlled by the Erlang VM and the OS. Callers are
/// responsible for applying higher-level framing and size limits.
///
/// Example:
/// ```gleam
/// import sad/ffi
///
/// ffi.open_port("/bin/echo", ["hello"], [], ".")
/// ```
pub fn open_port(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  cd: String,
) -> Result(Port, String) {
  open_port_ffi(command, args, env, cd)
}

@external(erlang, "sad_ffi", "open_port")
fn open_port_ffi(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  cd: String,
) -> Result(Port, String)

/// Sends data to an open port.
///
/// Example:
/// ```gleam
/// import sad/ffi
///
/// // After `open_port`, write input to the child process:
/// // ffi.port_send(port, "input\n")
/// ```
pub fn port_send(port: Port, data: String) -> Nil {
  port_send_ffi(port, data)
}

@external(erlang, "sad_ffi", "port_send")
fn port_send_ffi(port: Port, data: String) -> Nil

/// Closes an open port.
///
/// Example:
/// ```gleam
/// import sad/ffi
///
/// // ffi.port_close(port)
/// ```
pub fn port_close(port: Port) -> Nil {
  port_close_ffi(port)
}

@external(erlang, "sad_ffi", "port_close")
fn port_close_ffi(port: Port) -> Nil

/// Receives a message from a port.
///
/// Returns `Error(Nil)` on timeout.
///
/// Example:
/// ```gleam
/// import sad/ffi
///
/// // case ffi.port_receive(port, 1000) { ... }
/// ```
pub fn port_receive(port: Port, timeout_ms: Int) -> Result(PortMessage, Nil) {
  port_receive_ffi(port, timeout_ms)
}

@external(erlang, "sad_ffi", "port_receive")
fn port_receive_ffi(port: Port, timeout_ms: Int) -> Result(PortMessage, Nil)

/// Checks whether `host:port` can be bound (best effort).
///
/// Returns `Ok(Nil)` if binding is possible, otherwise `Error(reason)`.
pub fn check_port_available(host: String, port: Int) -> Result(Nil, String) {
  check_port_available_ffi(host, port)
}

@external(erlang, "sad_ffi", "check_port_available")
fn check_port_available_ffi(host: String, port: Int) -> Result(Nil, String)
