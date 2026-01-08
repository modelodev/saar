import envoy
import gleam/erlang/process
import gleam/int
import gleam/list
import sad/bridge/port_process
import test_assertions

pub const default_read_timeout_ms = 200

pub fn ensure_wrapper_path() {
  envoy.set("SAD_WRAPPER_PATH", "./priv/sad_wrapper")
}

pub fn base_env(
  shutdown_ms: Int,
  extra: List(#(String, String)),
) -> List(#(String, String)) {
  let path_env = case envoy.get("PATH") {
    Ok(path) -> [#("PATH", path)]
    Error(_) -> []
  }

  list.append(path_env, [
    #("SAD_SHUTDOWN_MS", int.to_string(shutdown_ms)),
    #("SAD_WRAPPER_FORCE_FALLBACK", "1"),
    ..extra
  ])
}

pub fn env_with_workspace(
  shutdown_ms: Int,
  workspace: String,
) -> List(#(String, String)) {
  base_env(shutdown_ms, [#("SAD_WORKSPACE", workspace)])
}

pub fn start_process(
  runner_path: String,
  runner_args: List(String),
  shutdown_ms: Int,
  cwd: String,
  max_event_bytes: Int,
) -> port_process.PortProcess {
  process.trap_exits(True)
  ensure_wrapper_path()

  port_process.start(
    runner_path,
    runner_args,
    base_env(shutdown_ms, []),
    cwd,
    max_event_bytes,
  )
  |> test_assertions.assert_ok
}

pub fn read_line_with_retries(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) -> Result(String, port_process.PortReadError) {
  case attempts {
    0 -> Error(port_process.Timeout)
    _ ->
      case port_process.read_line(process, timeout_ms) {
        Ok(line) -> Ok(line)
        Error(port_process.Timeout) ->
          read_line_with_retries(process, timeout_ms, attempts - 1)
        Error(error) -> Error(error)
      }
  }
}

pub fn read_noeol_fragment(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) -> Result(String, Nil) {
  case attempts {
    0 -> Error(Nil)
    _ ->
      case port_process.receive(process, timeout_ms) {
        Ok(port_process.PortNoeol(fragment)) -> Ok(fragment)
        Ok(port_process.PortExit(_)) ->
          read_noeol_fragment(process, timeout_ms, attempts - 1)
        Ok(_) -> Error(Nil)
        Error(_) -> read_noeol_fragment(process, timeout_ms, attempts - 1)
      }
  }
}

pub fn wait_for_exit(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) {
  case attempts {
    0 -> panic as "Timed out waiting for port exit"
    _ ->
      case port_process.receive(process, timeout_ms) {
        Ok(port_process.PortExit(_)) -> Nil
        Ok(_) -> wait_for_exit(process, timeout_ms, attempts - 1)
        Error(_) -> wait_for_exit(process, timeout_ms, attempts - 1)
      }
  }
}

pub fn wait_for_exit_optional(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) {
  case attempts {
    0 -> Nil
    _ ->
      case port_process.receive(process, timeout_ms) {
        Ok(port_process.PortExit(_)) -> Nil
        Ok(_) -> wait_for_exit_optional(process, timeout_ms, attempts - 1)
        Error(_) -> wait_for_exit_optional(process, timeout_ms, attempts - 1)
      }
  }
}
