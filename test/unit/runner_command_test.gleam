import gleam/dict
import gleam/option.{type Option, None, Some}
import gleeunit
import gleeunit/should
import saar/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

fn base_runner(
  tool_config: types_runner.ToolConfig,
  exec_path: Option(String),
  args: List(String),
) -> types_runner.Runner {
  types_runner.Runner(
    type_: "generic_uvx",
    tool_config: tool_config,
    runtime: types_runner.default_runtime_config(),
    env_map: dict.new(),
    args: args,
    artifact_config: types_runner.default_artifact_config(),
    exec_path: exec_path,
  )
}

pub fn exec_command_prefers_exec_path_test() {
  let runner =
    base_runner(
      types_runner.ToolConfigPackage(
        package: "aider-chat",
        command: "aider",
        with_packages: ["pip"],
      ),
      Some("/tmp/generic_uvx_server.py"),
      ["--host", "127.0.0.1"],
    )

  types_runner.runner_exec_command(runner, "python3")
  |> should.equal(
    #("python3", ["/tmp/generic_uvx_server.py", "--host", "127.0.0.1"]),
  )
}

pub fn exec_command_uses_script_when_no_exec_path_test() {
  let runner =
    base_runner(types_runner.ToolConfigScript("echo.py"), None, ["--foo"])

  types_runner.runner_exec_command(runner, "python3")
  |> should.equal(#("python3", ["echo.py", "--foo"]))
}

pub fn exec_command_uses_package_when_no_exec_path_test() {
  let runner =
    base_runner(
      types_runner.ToolConfigPackage(
        package: "aider-chat",
        command: "aider",
        with_packages: ["pip", "uvicorn"],
      ),
      None,
      ["--bar"],
    )

  types_runner.runner_exec_command(runner, "python3")
  |> should.equal(#("aider", ["aider-chat", "pip", "uvicorn", "--bar"]))
}
