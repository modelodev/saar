////
//// Mission: interpolate runner definitions before provisioning/execution.
////
//// Responsibilities:
//// - Resolve `runner.args` and `runner.env_map` templates using runtime context.
//// - Return an updated `Runner` with concrete values.
////
//// Non-responsibilities:
//// - Executing runners or managing IO.
//// - Resolving params or building inputs.
////
//// Relationships:
//// - Used by provisioning flow to pre-resolve runner templates.
//// - Uses `saar/bridge/interpolator` for interpolation.

import gleam/option
import gleam/result
import saar/bridge/interpolator
import saar/types/input as types_input
import saar/types/output as types_output
import saar/types/resolved_params
import saar/types/runner as types_runner

/// Interpolates runner args/env_map for a given context.
pub fn interpolate_runner_def(
  runner: types_runner.Runner,
  params: resolved_params.ResolvedParams,
  input: types_input.InputPayload,
  context: types_input.RequestContext,
  runner_host: option.Option(String),
  runner_port: option.Option(Int),
) -> Result(types_runner.Runner, types_output.SaarError) {
  let ctx =
    interpolator.build_context(params, input, context, runner_host, runner_port)

  use env_map <- result.try(interpolator.interpolate_dict(runner.env_map, ctx))
  use args <- result.try(interpolator.interpolate_list(runner.args, ctx))

  Ok(types_runner.Runner(..runner, env_map: env_map, args: args))
}
