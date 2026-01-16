import envoy
import gleam/dict
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option
import saar/bridge/http_client
import saar/bridge/port_process
import test_assertions

pub const default_read_timeout_ms = 200

pub fn ensure_wrapper_path() {
  envoy.set("SAAR_WRAPPER_PATH", "./priv/saar_wrapper")
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
    #("SAAR_SHUTDOWN_MS", int.to_string(shutdown_ms)),
    #("SAAR_WRAPPER_FORCE_FALLBACK", "1"),
    ..extra
  ])
}

pub fn env_with_workspace(
  shutdown_ms: Int,
  workspace: String,
) -> List(#(String, String)) {
  base_env(shutdown_ms, [#("SAAR_WORKSPACE", workspace)])
}

pub fn start_process(
  runner_path: String,
  runner_args: List(String),
  shutdown_ms: Int,
  cwd: String,
  max_event_bytes: Int,
) -> port_process.PortProcess {
  start_process_with_env(
    runner_path,
    runner_args,
    base_env(shutdown_ms, []),
    cwd,
    max_event_bytes,
  )
}

pub fn start_process_with_env(
  runner_path: String,
  runner_args: List(String),
  env: List(#(String, String)),
  cwd: String,
  max_event_bytes: Int,
) -> port_process.PortProcess {
  process.trap_exits(True)
  ensure_wrapper_path()

  port_process.start(runner_path, runner_args, env, cwd, max_event_bytes)
  |> test_assertions.assert_ok
}

pub fn read_line_with_retries(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) -> #(port_process.PortProcess, Result(String, port_process.PortReadError)) {
  case attempts {
    0 -> #(process, Error(port_process.Timeout))
    _ ->
      case port_process.read_line(process, timeout_ms) {
        #(next_process, Ok(line)) -> #(next_process, Ok(line))
        #(next_process, Error(port_process.Timeout)) ->
          read_line_with_retries(next_process, timeout_ms, attempts - 1)
        #(next_process, Error(error)) -> #(next_process, Error(error))
      }
  }
}

pub fn read_noeol_fragment(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) -> #(port_process.PortProcess, Result(String, port_process.PortReadError)) {
  case attempts {
    0 -> #(process, Error(port_process.Timeout))
    _ ->
      case port_process.read_line(process, timeout_ms) {
        #(next_process, Error(port_process.NoeolFragment(fragment))) -> #(
          next_process,
          Ok(fragment),
        )
        #(next_process, Error(port_process.Timeout)) ->
          read_noeol_fragment(next_process, timeout_ms, attempts - 1)
        #(next_process, Ok(_)) ->
          read_noeol_fragment(next_process, timeout_ms, attempts - 1)
        #(next_process, Error(error)) -> #(next_process, Error(error))
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

pub fn wait_for_http_200(url: String, attempts: Int, delay_ms: Int) {
  case attempts {
    0 -> panic as "Timed out waiting for HTTP 200"

    _ ->
      case
        http_client.request_sync_string(
          http.Get,
          url,
          dict.new(),
          option.None,
          200,
          2048,
        )
      {
        Ok(resp) if resp.status == 200 -> Nil
        _ -> {
          process.sleep(delay_ms)
          wait_for_http_200(url, attempts - 1, delay_ms)
        }
      }
  }
}
