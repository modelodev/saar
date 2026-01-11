//// Port-backed runner process management.
////
//// Mission: manage the wrapper/runner port lifecycle and IO boundaries.
////
//// Responsibilities:
//// - Start the wrapper process via `sad/ffi` with the configured limits.
//// - Send control lines and read JSONL output with size checks.
//// - Delegate JSONL framing to `sad/bridge/jsonl_framer`.
////
//// Non-responsibilities:
//// - Parsing runner events into domain types.
//// - Deciding retries or timeouts for higher-level workflows.
////
//// Relationships:
//// - Uses `sad/ffi` for port IO and `gleam/erlang/application` for priv lookup.
//// - Uses `sad/bridge/jsonl_framer` for newline framing.
//// - Consumed by `sad/bridge/runner` as the port boundary.

import envoy
import filepath
import gleam/erlang/application
import gleam/erlang/port.{type Port}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sad/bridge/jsonl_framer
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
  let framer = jsonl_framer.from_buffer(process.max_event_bytes, process.buffer)
  let #(next_framer, popped) = jsonl_framer.pop_line(framer)
  let next_process =
    PortProcess(..process, buffer: jsonl_framer.buffer(next_framer))

  case popped {
    Ok(Some(line)) -> #(next_process, Ok(line))

    Ok(None) ->
      case receive(next_process, timeout_ms) {
        Ok(PortChunk(chunk)) -> {
          let framer =
            jsonl_framer.from_buffer(
              next_process.max_event_bytes,
              next_process.buffer,
            )
          let #(next_framer, pushed) = jsonl_framer.push_chunk(framer, chunk)
          let next_process =
            PortProcess(
              ..next_process,
              buffer: jsonl_framer.buffer(next_framer),
            )

          case pushed {
            Ok(_) -> read_line(next_process, timeout_ms)
            Error(err) -> #(
              next_process,
              Error(framer_error_to_read_error(err)),
            )
          }
        }

        Ok(PortExit(status)) -> {
          let framer =
            jsonl_framer.from_buffer(
              next_process.max_event_bytes,
              next_process.buffer,
            )
          let #(next_framer, finalized) = jsonl_framer.finalize(framer)
          let next_process =
            PortProcess(
              ..next_process,
              buffer: jsonl_framer.buffer(next_framer),
            )

          case finalized {
            Ok(_) -> #(next_process, Error(PortExited(status)))
            Error(err) -> #(
              next_process,
              Error(framer_error_to_read_error(err)),
            )
          }
        }

        Error(_) -> #(next_process, Error(Timeout))
      }

    Error(err) -> #(next_process, Error(framer_error_to_read_error(err)))
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

fn framer_error_to_read_error(err: jsonl_framer.FramerError) -> PortReadError {
  case err {
    jsonl_framer.OversizedEvent(size: size, max: max) ->
      OversizedEvent(size: size, max: max)

    jsonl_framer.NoeolFragment(fragment) -> NoeolFragment(fragment)
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
