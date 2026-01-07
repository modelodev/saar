import envoy
import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit
import gleeunit/should
import sad/bridge/port_process
import sad/runner_contract_min
import sad/types
import test_assertions

const max_event_bytes = 262_144
const read_timeout_ms = 200

pub fn main() {
  gleeunit.main()
}

pub fn wrapper_is_silent_on_stdout_test() {
  let process = start_process("/bin/true", [], 500)
  assert_no_stdout_until_exit(process, 10)
}

pub fn wrapper_eof_triggers_stop_no_orphans_test() {
  let process = start_process("/bin/sh", ["-c", "sleep 60"], 500)
  port_process.close(process)
  wait_for_exit(process, 20)
}

pub fn wrapper_stop_message_triggers_stop_no_orphans_test() {
  let process = start_process("/bin/sh", ["-c", "sleep 60"], 500)
  port_process.send(process, "{\"t\":\"stop\"}")
  wait_for_exit(process, 20)
}

pub fn wrapper_stop_timeout_escalates_to_sigkill_test() {
  let script =
    "import signal, time; signal.signal(signal.SIGTERM, lambda *_: None); time.sleep(60)"
  let process = start_process("python3", ["-c", script], 200)
  port_process.send(process, "{\"t\":\"stop\"}")
  wait_for_exit(process, 40)
}

pub fn noeol_fragment_is_infra_error_test() {
  let script =
    "import sys, time; sys.stdout.write('{\"t\":\"result\",\"status\":\"success\"}'); sys.stdout.flush(); time.sleep(0.2)"
  let process = start_process("python3", ["-c", script], 500)

  case read_noeol_fragment(process, 10) {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected noeol fragment error"
  }

  wait_for_exit(process, 10)
}

pub fn echo_cli_result_is_received_test() {
  let process =
    start_process(
      "python3",
      ["./test/fixtures/source_local/runners/echo_cli.py"],
      500,
    )

  let input =
    "{\"params\":{\"delay_ms\":0},\"input\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}}"
  port_process.send(process, input)
  process.sleep(20)
  port_process.send(process, "{\"t\":\"stop\"}")

  let line = read_line_with_retries(process, 10) |> test_assertions.assert_ok

  let event = runner_contract_min.decode_runner_event(line)
  let event = test_assertions.assert_ok(event)

  case event {
    types.RunnerEventResult(response) ->
      response.status |> should.equal(types.StatusSuccess)
    _ -> panic as "Expected t=result event"
  }

  wait_for_exit(process, 10)
}

fn start_process(
  runner_path: String,
  runner_args: List(String),
  shutdown_ms: Int,
) -> port_process.PortProcess {
  process.trap_exits(True)
  ensure_wrapper_path()

  port_process.start(
    runner_path,
    runner_args,
    base_env(shutdown_ms),
    ".",
    max_event_bytes,
  )
  |> test_assertions.assert_ok
}

fn ensure_wrapper_path() {
  envoy.set("SAD_WRAPPER_PATH", "./priv/sad_wrapper")
}

fn base_env(shutdown_ms: Int) -> List(#(String, String)) {
  let path_env =
    case envoy.get("PATH") {
      Ok(path) -> [#("PATH", path)]
      Error(_) -> []
    }

  list.append(
    path_env,
    [
      #("SAD_SHUTDOWN_MS", int.to_string(shutdown_ms)),
      #("SAD_WRAPPER_FORCE_FALLBACK", "1"),
    ],
  )
}

fn read_line_with_retries(
  process: port_process.PortProcess,
  attempts: Int,
) -> Result(String, port_process.PortReadError) {
  case attempts {
    0 -> Error(port_process.Timeout)
    _ ->
      case port_process.read_line(process, read_timeout_ms) {
        Ok(line) -> Ok(line)
        Error(port_process.Timeout) -> read_line_with_retries(process, attempts - 1)
        Error(error) -> Error(error)
      }
  }
}

fn read_noeol_fragment(
  process: port_process.PortProcess,
  attempts: Int,
) -> Result(String, Nil) {
  case attempts {
    0 -> Error(Nil)
    _ ->
      case port_process.receive(process, read_timeout_ms) {
        Ok(port_process.PortNoeol(fragment)) -> Ok(fragment)
        Ok(port_process.PortExit(_)) -> read_noeol_fragment(process, attempts - 1)
        Ok(_) -> Error(Nil)
        Error(_) -> read_noeol_fragment(process, attempts - 1)
      }
  }
}

fn wait_for_exit(process: port_process.PortProcess, attempts: Int) {
  case attempts {
    0 -> panic as "Timed out waiting for port exit"
    _ ->
      case port_process.receive(process, read_timeout_ms) {
        Ok(port_process.PortExit(_)) -> Nil
        Ok(_) -> wait_for_exit(process, attempts - 1)
        Error(_) -> wait_for_exit(process, attempts - 1)
      }
  }
}

fn assert_no_stdout_until_exit(
  process: port_process.PortProcess,
  attempts: Int,
) {
  case attempts {
    0 -> panic as "Timed out waiting for port exit"
    _ ->
      case port_process.receive(process, read_timeout_ms) {
        Ok(port_process.PortLine(line)) ->
          panic as { "Unexpected stdout line: " <> line }
        Ok(port_process.PortNoeol(fragment)) ->
          panic as { "Unexpected stdout fragment: " <> fragment }
        Ok(port_process.PortExit(_)) -> Nil
        Error(_) -> assert_no_stdout_until_exit(process, attempts - 1)
      }
  }
}
