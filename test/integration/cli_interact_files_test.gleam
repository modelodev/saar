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

pub fn interact_with_files_by_url() {
  port_helpers.ensure_wrapper_path()
  let base_url = tasks_helpers.start_saar()
  let instance_id = "inst-cli-files-1"

  tasks_helpers.create_agent(base_url, "echo_files_one", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 300)

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
        "interact",
        "--instance",
        instance_id,
        "--capability",
        "files",
        "--file-url",
        "https://example.com/intro.pdf",
        "--file-name",
        "intro.pdf",
        "--file-mime",
        "application/pdf",
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

  should.equal(string.contains(output, "intro.pdf"), True)
  should.equal(string.contains(output, "application/pdf"), True)

  let _exit = wait_for_exit_code(process, 200, 40)
}

pub fn download_artifacts_success() {
  port_helpers.ensure_wrapper_path()
  let base_url = tasks_helpers.start_saar()
  let instance_id = "inst-cli-artifacts-1"

  tasks_helpers.create_agent(base_url, "artifact_gen", instance_id)
  tasks_helpers.wait_phase(base_url, instance_id, "ready_transient", 300)

  let port = extract_port(base_url)
  let config_path = write_cli_config(port)
  let output_dir = "/tmp/saar-cli-artifacts-" <> int.to_string(port)

  let env = port_helpers.base_env(2000, [#("SAAR_TEST_API_KEY", "test-key")])

  let process =
    port_process.start(
      "gleam",
      [
        "run",
        "-m",
        "saar",
        "--",
        "interact",
        "--instance",
        instance_id,
        "--capability",
        "generate",
        "--content",
        "report",
        "--output",
        output_dir,
        "--config",
        config_path,
      ],
      env,
      ".",
      262_144,
    )
    |> test_assertions.assert_ok

  let #(process, _line) = port_helpers.read_line_with_retries(process, 200, 40)
  let _exit = wait_for_exit_code(process, 200, 40)

  let report_path = output_dir <> "/report.pdf"
  let contents = simplifile.read(report_path) |> test_assertions.assert_ok
  should.equal(string.contains(contents, "%PDF-1.4"), True)
}

pub fn interact_with_files_by_url_test() {
  interact_with_files_by_url()
}

pub fn download_artifacts_success_test() {
  download_artifacts_success()
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
