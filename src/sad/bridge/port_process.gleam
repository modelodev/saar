import envoy
import filepath
import gleam/erlang/port.{type Port}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sad/ffi
import simplifile

pub type PortProcess {
  PortProcess(port: Port, wrapper_path: String)
}

pub type PortError {
  WrapperNotFound(String)
  SpawnFailed(String)
}

pub type PortEvent {
  PortLine(String)
  PortNoeol(String)
  PortExit(Int)
}

pub type PortReadError {
  NoeolFragment(String)
  PortExited(Int)
  Timeout
}

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
    Ok(port) -> Ok(PortProcess(port: port, wrapper_path: wrapper))
    Error(reason) -> Error(SpawnFailed(reason))
  }
}

pub fn send(process: PortProcess, data: String) -> Nil {
  let PortProcess(port:, ..) = process
  ffi.port_send(port, data)
}

pub fn close(process: PortProcess) -> Nil {
  let PortProcess(port:, ..) = process
  ffi.port_close(port)
}

pub fn receive(process: PortProcess, timeout_ms: Int) -> Result(PortEvent, Nil) {
  let PortProcess(port:, ..) = process

  case ffi.port_receive(port, timeout_ms) {
    Ok(ffi.PortDataEol(line)) -> Ok(PortLine(line))
    Ok(ffi.PortDataNoeol(fragment)) -> Ok(PortNoeol(fragment))
    Ok(ffi.PortExit(status)) -> Ok(PortExit(status))
    Error(_) -> Error(Nil)
  }
}

pub fn read_line(
  process: PortProcess,
  timeout_ms: Int,
) -> Result(String, PortReadError) {
  case receive(process, timeout_ms) {
    Ok(PortLine(line)) -> Ok(line)
    Ok(PortNoeol(fragment)) -> Error(NoeolFragment(fragment))
    Ok(PortExit(status)) -> Error(PortExited(status))
    Error(_) -> Error(Timeout)
  }
}

pub fn wrapper_path(process: PortProcess) -> String {
  let PortProcess(wrapper_path:, ..) = process
  wrapper_path
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
  let priv_candidate = case ffi.priv_dir() {
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
