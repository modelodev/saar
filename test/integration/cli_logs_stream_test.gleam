import gleam/int
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import port_helpers
import saar/bridge/port_process
import simplifile
import tasks_helpers
import test_assertions

pub fn main() {
  gleeunit.main()
}

pub fn logs_stream_receives_data() {
  port_helpers.ensure_wrapper_path()
  let base_url = tasks_helpers.start_saar()
  let instance_id = "inst-cli-logs-1"

  tasks_helpers.create_agent(base_url, "log_server", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_continuous", 300)

  let port = extract_port(base_url)
  let config_path = write_cli_config(port)

  let env = port_helpers.base_env(2000, [#("SAAR_TEST_API_KEY", "test-key")])

  let process =
    port_process.start(
      "gleam",
      [
        "run",
        "-m",
        "saar",
        "--",
        "agent",
        "logs",
        instance_id,
        "--config",
        config_path,
      ],
      env,
      ".",
      262_144,
    )
    |> test_assertions.assert_ok

  let #(process, line) = port_helpers.read_line_with_retries(process, 200, 40)
  let output = line |> test_assertions.assert_ok

  should.equal(string.contains(output, "server-start"), True)

  port_process.close(process)
  let _exit = wait_for_exit_code(process, 200, 40)
}

pub fn logs_stream_receives_data_test() {
  logs_stream_receives_data()
}

fn extract_port(base_url: String) -> Int {
  let parts = string.split(base_url, on: ":")
  let assert Ok(port_str) = list.last(parts)
  let assert Ok(port) = int.parse(port_str)
  port
}

fn write_cli_config(port: Int) -> String {
  let path = "/tmp/saar-cli-config-" <> int.to_string(port) <> ".toml"

  let raw =
    simplifile.read("test/fixtures/config/test_config.toml")
    |> test_assertions.assert_ok

  let updated =
    string.replace(raw, "port = 0", "port = " <> int.to_string(port))

  simplifile.write(path, updated) |> test_assertions.assert_ok
  path
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
