import envoy
import gleam/int
import gleam/list
import gleeunit
import gleeunit/should
import port_helpers
import sad/bridge/port_process
import sad/bridge/runner_contract
import sad/ffi

const max_event_bytes = 262_144

const read_timeout_ms = port_helpers.default_read_timeout_ms

pub fn main() {
  gleeunit.main()
}

pub fn wrapper_stop_message_terminates_child_test() {
  let process = start_child("wait_stdin", [], 200, max_event_bytes)

  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit(process, read_timeout_ms, 20)
}

pub fn wrapper_sigterm_escalates_to_sigkill_test() {
  let process = start_child("ignore_sigterm", [], 200, max_event_bytes)

  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit(process, read_timeout_ms, 40)
}

pub fn wrapper_stop_timing_respects_double_shutdown_test() {
  let shutdown_ms = 120
  let post_kill_wait_ms = 80
  let env =
    port_helpers.base_env(shutdown_ms, [
      #("SAD_WRAPPER_POST_KILL_WAIT_MS", int.to_string(post_kill_wait_ms)),
      #("SAD_WRAPPER_POLL_MS", "10"),
    ])
  let process =
    port_helpers.start_process_with_env(
      "python3",
      child_args("ignore_sigterm", []),
      env,
      ".",
      max_event_bytes,
    )

  let start_ms = ffi.now_ms()
  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit(process, 50, 80)
  let elapsed = ffi.now_ms() - start_ms
  let expected_min = shutdown_ms * 2
  should.equal(elapsed >= expected_min - 10, True)
}

pub fn wrapper_noeol_fragment_is_infra_error_test() {
  let process = start_child("partial_line", [], 500, max_event_bytes)

  let #(process, fragment_result) =
    port_helpers.read_noeol_fragment(process, read_timeout_ms, 20)
  fragment_result
  |> should.equal(Ok("HELLO"))

  port_helpers.wait_for_exit_optional(process, read_timeout_ms, 20)
}

pub fn wrapper_rejects_oversize_line_test() {
  let small_max = 64
  let process =
    start_child("long_line", [int.to_string(small_max + 10)], 500, small_max)

  let #(process, read_result) = port_process.read_line(process, read_timeout_ms)

  case read_result {
    Error(port_process.OversizedEvent(_, _)) -> Nil
    _ -> panic as "Expected OversizedEvent"
  }

  port_helpers.wait_for_exit_optional(process, read_timeout_ms, 20)
}

pub fn wrapper_enforces_stdout_byte_limit_test() {
  let max_stdout_bytes = 500
  let process = start_child("spam_bytes", ["2000", "100"], 500, max_event_bytes)

  read_until_exceeded(process, max_stdout_bytes, 0, 200)
  |> should.equal(Ok(Nil))

  port_process.send(process, "{\"t\":\"stop\"}\n")
  port_helpers.wait_for_exit_optional(process, read_timeout_ms, 40)
}

pub fn wrapper_missing_path_errors_test() {
  envoy.set("SAD_WRAPPER_PATH", "./priv/nope_wrapper")
  let env = port_helpers.base_env(500, [])

  let result =
    port_process.start(
      "python3",
      child_args("exit_code", ["0"]),
      env,
      ".",
      max_event_bytes,
    )

  case result {
    Error(port_process.SpawnFailed(_)) -> Nil
    Error(port_process.WrapperNotFound(_)) ->
      panic as "Expected spawn failure, got wrapper missing"
    Ok(_) -> panic as "Expected spawn failure"
  }

  port_helpers.ensure_wrapper_path()
}

fn start_child(
  mode: String,
  extra_args: List(String),
  shutdown_ms: Int,
  max_event_bytes: Int,
) -> port_process.PortProcess {
  port_helpers.start_process(
    "python3",
    child_args(mode, extra_args),
    shutdown_ms,
    ".",
    max_event_bytes,
  )
}

fn child_args(mode: String, extra_args: List(String)) -> List(String) {
  list.append(["./priv/testbin/child.py", mode], extra_args)
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
        #(process, Ok(line)) ->
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

        #(process, Error(port_process.Timeout)) ->
          read_until_exceeded(process, max_stdout_bytes, total, attempts - 1)
        #(_, Error(error)) ->
          Error("Unexpected read error: " <> int.to_string(error_code(error)))
      }
  }
}

fn error_code(error: port_process.PortReadError) -> Int {
  case error {
    port_process.OversizedEvent(_, _) -> 2
    port_process.NoeolFragment(_) -> 1
    port_process.PortExited(code) -> code
    port_process.Timeout -> 0
  }
}
