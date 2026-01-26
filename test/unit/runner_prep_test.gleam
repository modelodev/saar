import gleam/dict
import gleam/option
import gleeunit
import gleeunit/should
import saar/bridge/runner_prep
import saar/types/core as types_core
import saar/types/input as types_input
import saar/types/resolved_params
import saar/types/runner as types_runner

pub fn main() {
  gleeunit.main()
}

pub fn interpolate_runner_args_and_env_test() {
  let runner =
    types_runner.Runner(
      type_: "generic_uvx",
      tool_config: types_runner.ToolConfigPackage(
        "pkg",
        "tool",
        [],
        option.None,
      ),
      runtime: types_runner.default_runtime_config(),
      env_map: dict.from_list([#("HOST", "{{runner.host}}")]),
      args: ["--port", "{{runner.port}}"],
      artifact_config: types_runner.default_artifact_config(),
      exec_path: option.None,
    )

  let ctx =
    types_input.RequestContext(
      trace_id: types_core.trace_id("trace-1"),
      extra: dict.new(),
    )

  let input = types_input.PayloadChat([], dict.new())

  let params: resolved_params.ResolvedParams = dict.new()

  let assert Ok(updated) =
    runner_prep.interpolate_runner_def(
      runner,
      params,
      input,
      ctx,
      option.Some("127.0.0.1"),
      option.Some(9001),
    )

  updated.env_map |> should.equal(dict.from_list([#("HOST", "127.0.0.1")]))
  updated.args |> should.equal(["--port", "9001"])
}
