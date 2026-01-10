//// Port-backed runner process management.
////
//// Mission: manage the wrapper/runner port lifecycle and IO boundaries.
////
//// Responsibilities:
//// - Start the wrapper process via `sad/ffi` with the configured limits.
//// - Send control lines and read JSONL output with size checks.
////
//// Non-responsibilities:
//// - Parsing runner events into domain types.
//// - Deciding retries or timeouts for higher-level workflows.
////
//// Relationships:
//// - Uses `sad/ffi` for port IO and `gleam/erlang/application` for priv lookup.
//// - Consumed by `sad/bridge/runner` as the port boundary.

import envoy
import filepath
import gleam/erlang/application
import gleam/erlang/port.{type Port}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sad/ffi
import simplifile

/// Stateful handle for an open wrapper port process.
pub type PortProcess {
  PortProcess(
    port: Port,
    wrapper_path: String,
    buffer: String,
    max_event_bytes: Int,
  )
}

/// Errors returned when starting a port process.
pub type PortError {
  WrapperNotFound(String)
  SpawnFailed(String)
}

/// Events emitted by the port boundary.
pub type PortEvent {
  PortChunk(String)
  PortExit(Int)
}

/// Errors returned when reading lines from the port.
pub type PortReadError {
  OversizedEvent(size: Int, max: Int)
  NoeolFragment(String)
  PortExited(Int)
  Timeout
}

/// Starts the wrapper and returns a `PortProcess` handle.
///
/// Example:
/// ```gleam
/// import sad/bridge/port_process
///
/// port_process.start("./runner", [], [], ".", 262_144)
/// ```
pub fn start(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  max_runner_event_bytes: Int,
) -> Result(PortProcess, PortError) {
  use wrapper <- result.try(resolve_wrapper_path())

  let args = ["--", runner_path, ..runner_args]

  case ffi.open_port(wrapper, args, env, cwd, max_runner_event_bytes) {
    Ok(port) ->
      Ok(PortProcess(
        port: port,
        wrapper_path: wrapper,
        buffer: "",
        max_event_bytes: max_runner_event_bytes,
      ))
    Error(reason) -> Error(SpawnFailed(reason))
  }
}

/// Sends data to the port stdin.
///
/// Example:
/// ```gleam
/// import sad/bridge/port_process
///
/// // port_process.send(process, "{\"t\":\"stop\"}\n")
/// ```
pub fn send(process: PortProcess, data: String) -> Nil {
  let PortProcess(port:, ..) = process
  ffi.port_send(port, data)
}

/// Closes the underlying port.
///
/// Example:
/// ```gleam
/// import sad/bridge/port_process
///
/// // port_process.close(process)
/// ```
pub fn close(process: PortProcess) -> Nil {
  let PortProcess(port:, ..) = process
  ffi.port_close(port)
}

/// Receives the next port event, or `Error` on timeout.
///
/// Example:
/// ```gleam
/// import sad/bridge/port_process
///
/// // port_process.receive(process, 1000)
/// ```
pub fn receive(process: PortProcess, timeout_ms: Int) -> Result(PortEvent, Nil) {
  let PortProcess(port:, ..) = process

  case ffi.port_receive(port, timeout_ms) {
    Ok(ffi.PortDataChunk(chunk)) -> Ok(PortChunk(chunk))
    Ok(ffi.PortExit(status)) -> Ok(PortExit(status))
    Error(_) -> Error(Nil)
  }
}

/// Reads a single JSONL line from the port, tracking buffered fragments.
///
/// Example:
/// ```gleam
/// import sad/bridge/port_process
///
/// // port_process.read_line(process, 200)
/// ```
pub fn read_line(
  process: PortProcess,
  timeout_ms: Int,
) -> #(PortProcess, Result(String, PortReadError)) {
  case take_line(process.buffer) {
    Some(#(line, rest)) -> handle_line(process, line, rest)
    None ->
      case receive(process, timeout_ms) {
        Ok(PortChunk(chunk)) -> {
          let next_buffer = process.buffer <> chunk
          let next_process = PortProcess(..process, buffer: next_buffer)
          case take_line(next_buffer) {
            Some(#(line, rest)) -> handle_line(next_process, line, rest)
            None ->
              case string.byte_size(next_buffer) > process.max_event_bytes {
                True -> #(
                  PortProcess(..process, buffer: ""),
                  Error(OversizedEvent(
                    size: string.byte_size(next_buffer),
                    max: process.max_event_bytes,
                  )),
                )
                False -> read_line(next_process, timeout_ms)
              }
          }
        }
        Ok(PortExit(status)) ->
          case string.is_empty(process.buffer) {
            True -> #(process, Error(PortExited(status)))
            False -> #(
              PortProcess(..process, buffer: ""),
              Error(NoeolFragment(process.buffer)),
            )
          }
        Error(_) -> #(process, Error(Timeout))
      }
  }
}

/// Returns the resolved wrapper path.
///
/// Example:
/// ```gleam
/// import sad/bridge/port_process
///
/// // port_process.wrapper_path(process)
/// ```
pub fn wrapper_path(process: PortProcess) -> String {
  let PortProcess(wrapper_path:, ..) = process
  wrapper_path
}

fn take_line(buffer: String) -> Option(#(String, String)) {
  case string.split(buffer, "\n") {
    [] -> None
    [_single] -> None
    [line, ..rest] -> Some(#(line, string.join(rest, "\n")))
  }
}

fn handle_line(
  process: PortProcess,
  line: String,
  rest: String,
) -> #(PortProcess, Result(String, PortReadError)) {
  case string.byte_size(line) > process.max_event_bytes {
    True -> #(
      PortProcess(..process, buffer: ""),
      Error(OversizedEvent(
        size: string.byte_size(line),
        max: process.max_event_bytes,
      )),
    )
    False -> #(PortProcess(..process, buffer: rest), Ok(line))
  }
}

fn resolve_wrapper_path() -> Result(String, PortError) {
  case envoy.get("SAD_WRAPPER_PATH") {
    Ok(path) -> Ok(path)
    Error(_) -> {
      let candidates = wrapper_candidates()
      case first_existing(candidates) {
        Some(path) -> Ok(path)
        None -> Error(WrapperNotFound("sad_wrapper"))
      }
    }
  }
}

fn wrapper_candidates() -> List(String) {
  let priv_candidate = case application.priv_directory("sad") {
    Ok(dir) -> [filepath.join(dir, "sad_wrapper")]
    Error(_) -> []
  }

  list.append(priv_candidate, ["./priv/sad_wrapper"])
}

fn first_existing(paths: List(String)) -> Option(String) {
  case list.find(paths, is_existing_file) {
    Ok(path) -> Some(path)
    Error(_) -> None
  }
}

fn is_existing_file(path: String) -> Bool {
  case simplifile.is_file(path) {
    Ok(True) -> True
    _ -> False
  }
}
