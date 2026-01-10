import gleam/list
import gleeunit
import gleeunit/should
import port_helpers
import sad/bridge/port_process
import test_assertions

const max_event_bytes = 262_144

const read_timeout_ms = port_helpers.default_read_timeout_ms

pub fn main() {
  gleeunit.main()
}

pub fn port_open_reads_lines_test() {
  let process = start_child("print_lines", [], 500, max_event_bytes)

  let #(process, line1_result) =
    port_helpers.read_line_with_retries(process, read_timeout_ms, 10)
  let line1 = test_assertions.assert_ok(line1_result)
  line1 |> should.equal("hello")

  let #(process, line2_result) =
    port_helpers.read_line_with_retries(process, read_timeout_ms, 10)
  let line2 = test_assertions.assert_ok(line2_result)
  line2 |> should.equal("world")

  let #(process, line3_result) =
    port_helpers.read_line_with_retries(process, read_timeout_ms, 10)
  let line3 = test_assertions.assert_ok(line3_result)
  line3 |> should.equal("")

  port_helpers.wait_for_exit_optional(process, read_timeout_ms, 20)
}

pub fn port_missing_binary_exits_nonzero_test() {
  port_helpers.ensure_wrapper_path()
  let env = port_helpers.base_env(500, [])

  let process =
    port_process.start("missing-binary", [], env, ".", max_event_bytes)
    |> test_assertions.assert_ok

  let code =
    wait_for_exit_code(process, read_timeout_ms, 20)
    |> test_assertions.assert_ok

  case code == 0 {
    True -> panic as "Expected non-zero exit code"
    False -> Nil
  }
}

pub fn port_process_stays_alive_without_input_test() {
  let process = start_child("wait_stdin", [], 500, max_event_bytes)

  let #(_, read_result) = port_process.read_line(process, read_timeout_ms)
  read_result |> should.equal(Error(port_process.Timeout))

  port_process.close(process)
  port_helpers.wait_for_exit(process, read_timeout_ms, 20)
}

pub fn port_close_stdin_triggers_exit_test() {
  let process = start_child("wait_stdin", [], 500, max_event_bytes)

  port_process.close(process)
  port_helpers.wait_for_exit(process, read_timeout_ms, 20)
}

pub fn port_exit_code_zero_reported_test() {
  let process = start_child("exit_code", ["0"], 500, max_event_bytes)

  wait_for_exit_code(process, read_timeout_ms, 20)
  |> should.equal(Ok(0))
}

pub fn port_exit_code_nonzero_reported_test() {
  let process = start_child("exit_code", ["7"], 500, max_event_bytes)

  wait_for_exit_code(process, read_timeout_ms, 20)
  |> should.equal(Ok(7))
}

pub fn port_read_timeout_does_not_kill_test() {
  let process = start_child("wait_stdin", [], 500, max_event_bytes)

  let #(_, read_result) = port_process.read_line(process, read_timeout_ms)
  read_result |> should.equal(Error(port_process.Timeout))

  case port_process.receive(process, read_timeout_ms) {
    Ok(port_process.PortExit(_)) -> panic as "Expected process to stay alive"
    _ -> Nil
  }

  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit(process, read_timeout_ms, 20)
}

pub fn port_read_handles_chunked_line_test() {
  let script =
    "import sys, time; sys.stdout.write('hello'); sys.stdout.flush(); time.sleep(0.05); sys.stdout.write('world\\n'); sys.stdout.flush()"
  let process = start_child("python3", ["-c", script], 500, max_event_bytes)

  let #(process, line_result) =
    port_helpers.read_line_with_retries(process, read_timeout_ms, 10)
  let line = test_assertions.assert_ok(line_result)

  line |> should.equal("helloworld")

  port_helpers.wait_for_exit_optional(process, read_timeout_ms, 20)
}

fn start_child(
  mode: String,
  extra_args: List(String),
  shutdown_ms: Int,
  max_event_bytes: Int,
) -> port_process.PortProcess {
  case mode {
    "python3" ->
      port_helpers.start_process(
        "python3",
        extra_args,
        shutdown_ms,
        ".",
        max_event_bytes,
      )
    _ ->
      port_helpers.start_process(
        "python3",
        child_args(mode, extra_args),
        shutdown_ms,
        ".",
        max_event_bytes,
      )
  }
}

fn child_args(mode: String, extra_args: List(String)) -> List(String) {
  list.append(["./priv/testbin/child.py", mode], extra_args)
}

fn wait_for_exit_code(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) -> Result(Int, Nil) {
  case attempts {
    0 -> Error(Nil)
    _ ->
      case port_process.receive(process, timeout_ms) {
        Ok(port_process.PortExit(code)) -> Ok(code)
        Ok(_) -> wait_for_exit_code(process, timeout_ms, attempts - 1)
        Error(_) -> wait_for_exit_code(process, timeout_ms, attempts - 1)
      }
  }
}
