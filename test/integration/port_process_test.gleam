import gleeunit
import port_helpers
import sad/bridge/port_process
import sad/bridge/runner_contract
import sad/types/runner as types_runner
import test_assertions

const max_event_bytes = 262_144

const read_timeout_ms = port_helpers.default_read_timeout_ms

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
  port_helpers.wait_for_exit(process, read_timeout_ms, 20)
}

pub fn wrapper_stop_message_triggers_stop_no_orphans_test() {
  let process = start_process("/bin/sh", ["-c", "sleep 60"], 500)
  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit(process, read_timeout_ms, 20)
}

pub fn wrapper_stop_timeout_escalates_to_sigkill_test() {
  let script =
    "import signal, time; signal.signal(signal.SIGTERM, lambda *_: None); time.sleep(60)"
  let process = start_process("python3", ["-c", script], 200)
  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit(process, read_timeout_ms, 40)
}

pub fn noeol_fragment_is_infra_error_test() {
  let script =
    "import sys, time; sys.stdout.write('{\"t\":\"result\",\"status\":\"success\"}'); sys.stdout.flush(); time.sleep(0.2)"
  let process = start_process("python3", ["-c", script], 500)

  let #(process, result) =
    port_helpers.read_noeol_fragment(process, read_timeout_ms, 20)

  case result {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected noeol fragment error"
  }

  port_helpers.wait_for_exit(process, read_timeout_ms, 10)
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
  port_process.send(process, "{\"t\":\"input\",\"payload\":" <> input <> "}\n")

  let #(process, line_result) =
    port_helpers.read_line_with_retries(process, read_timeout_ms, 10)
  let line = test_assertions.assert_ok(line_result)

  let event = runner_contract.decode_event(line)
  let event = test_assertions.assert_ok(event)

  case event {
    types_runner.RunnerEventResult(types_runner.RunnerSuccess(..)) -> Nil
    types_runner.RunnerEventResult(types_runner.RunnerFailure(..)) ->
      panic as "Expected success runner result"
    _ -> panic as "Expected t=result event"
  }

  port_helpers.wait_for_exit(process, read_timeout_ms, 10)
}

fn start_process(
  runner_path: String,
  runner_args: List(String),
  shutdown_ms: Int,
) -> port_process.PortProcess {
  port_helpers.start_process(
    runner_path,
    runner_args,
    shutdown_ms,
    ".",
    max_event_bytes,
  )
}

fn assert_no_stdout_until_exit(process: port_process.PortProcess, attempts: Int) {
  case attempts {
    0 -> panic as "Timed out waiting for port exit"
    _ ->
      case port_process.receive(process, read_timeout_ms) {
        Ok(port_process.PortChunk(chunk)) ->
          panic as { "Unexpected stdout chunk: " <> chunk }
        Ok(port_process.PortExit(_)) -> Nil
        Error(_) -> assert_no_stdout_until_exit(process, attempts - 1)
      }
  }
}
