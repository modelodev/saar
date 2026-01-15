import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import sad/bridge/port_process
import simplifile
import test_assertions
import tom

pub fn main() {
  gleeunit.main()
}

pub fn version_command_runs_via_gleam_run() {
  let expected = expected_version() |> test_assertions.assert_ok

  port_helpers.ensure_wrapper_path()

  let env = port_helpers.base_env(5000, [])

  let process =
    port_process.start(
      "gleam",
      ["run", "-m", "sad", "--", "--version"],
      env,
      ".",
      262_144,
    )
    |> test_assertions.assert_ok

  let #(process, line) = port_helpers.read_line_with_retries(process, 200, 40)

  let printed = line |> test_assertions.assert_ok

  should.equal(string.contains(printed, expected), True)

  let exit_code = wait_for_exit_code(process, 200, 50)
  should.equal(exit_code, 0)
}

pub fn version_command_runs_via_gleam_run_test() {
  version_command_runs_via_gleam_run()
}

fn expected_version() -> Result(String, Nil) {
  use raw <- result.try(
    simplifile.read("./gleam.toml") |> result.map_error(fn(_) { Nil }),
  )
  use parsed <- result.try(tom.parse(raw) |> result.map_error(fn(_) { Nil }))

  tom.get_string(parsed, ["version"]) |> result.map_error(fn(_) { Nil })
}

fn wait_for_exit_code(
  process: port_process.PortProcess,
  timeout_ms: Int,
  attempts: Int,
) -> Int {
  case attempts {
    0 -> -1
    _ ->
      case port_process.receive(process, timeout_ms) {
        Ok(port_process.PortExit(code)) -> code
        Ok(_) -> wait_for_exit_code(process, timeout_ms, attempts - 1)
        Error(_) -> wait_for_exit_code(process, timeout_ms, attempts - 1)
      }
  }
}
