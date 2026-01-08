import gleam/int
import gleeunit
import gleeunit/should
import port_helpers
import sad/bridge/port_process
import sad/runner_contract

const read_timeout_ms = port_helpers.default_read_timeout_ms

pub fn main() {
  gleeunit.main()
}

pub fn rejects_noeol_fragment_test() {
  let script =
    "import sys, time; sys.stdout.write('{\"t\":\"result\",\"status\":\"success\"}'); sys.stdout.flush(); time.sleep(0.2)"
  let process = start_process("python3", ["-c", script], 500, 200)

  port_helpers.read_noeol_fragment(process, read_timeout_ms, 10)
  |> should.equal(Ok("{\"t\":\"result\",\"status\":\"success\"}"))

  port_helpers.wait_for_exit(process, read_timeout_ms, 10)
}

pub fn rejects_oversize_line_test() {
  let script =
    "import json, sys; sys.stdout.write(json.dumps({'t':'log','level':'info','message':'x'*200}) + '\\n'); sys.stdout.flush()"
  let process = start_process("python3", ["-c", script], 500, 50)

  case port_helpers.read_noeol_fragment(process, read_timeout_ms, 10) {
    Ok(_) -> Nil
    Error(_) -> panic as "Expected NoeolFragment"
  }

  port_helpers.wait_for_exit(process, read_timeout_ms, 10)
}

pub fn exceeds_max_stdout_bytes_test() {
  let process =
    start_process(
      "python3",
      ["./test/fixtures/source_local/runners/greedy_logger.py"],
      500,
      262_144,
    )

  let max_stdout_bytes = 5000

  read_until_exceeded(process, max_stdout_bytes, 0, 200)
  |> should.equal(Ok(Nil))

  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit_optional(process, read_timeout_ms, 40)
}

fn start_process(
  runner_path: String,
  runner_args: List(String),
  shutdown_ms: Int,
  max_event_bytes: Int,
) -> port_process.PortProcess {
  port_helpers.start_process(
    runner_path,
    runner_args,
    shutdown_ms,
    ".",
    max_event_bytes,
  )
}

fn read_until_exceeded(
  process: port_process.PortProcess,
  max_stdout_bytes: Int,
  total: Int,
  attempts: Int,
) -> Result(Nil, String) {
  case attempts {
    0 -> Error("Timed out waiting for stdout limit")
    _ ->
      case port_process.read_line(process, read_timeout_ms) {
        Ok(line) ->
          case
            runner_contract.enforce_max_stdout_bytes(
              total,
              line,
              max_stdout_bytes,
            )
          {
            Ok(next) ->
              read_until_exceeded(process, max_stdout_bytes, next, attempts - 1)
            Error(_) -> Ok(Nil)
          }

        Error(port_process.Timeout) ->
          read_until_exceeded(process, max_stdout_bytes, total, attempts - 1)
        Error(error) ->
          Error("Unexpected read error: " <> int.to_string(error_code(error)))
      }
  }
}

fn error_code(error: port_process.PortReadError) -> Int {
  case error {
    port_process.NoeolFragment(_) -> 1
    port_process.PortExited(code) -> code
    port_process.Timeout -> 0
  }
}
