//// Managed port environment injection.
////
//// Mission: build the environment variables required for runners started
//// under SAAR-managed ports.
////
//// Responsibilities:
//// - Resolve the bind host from `SaarConfig`.
//// - Inject `SAAR_HOST` and `SAAR_PORT` when a port is assigned.
//// - Inject configured `{host_env_var, port_env_var}` for managed-port runtimes.
//// - Provide managed-port environment variables when the runtime requires it.
////
//// Non-responsibilities:
//// - Starting runner processes.
//// - Performing readiness waits or retry loops.
////
//// Relationships:
//// - Used by `saar/bridge/runner` when starting continuous runners.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import saar/types/config as types_config
import saar/types/core as types_core
import saar/types/output as types_output
import saar/types/runner as types_runner

/// Returns the managed-port host configured in `SaarConfig`.
pub fn managed_port_host(config: types_config.SaarConfig) -> String {
  let types_config.SaarConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(managed_port_host: host, ..) = runner_cfg
  host
}

/// Builds managed-port environment variables for a runner.
///
/// This injects `SAAR_HOST` and `SAAR_PORT` when a port is assigned and the
/// runtime uses managed ports. It also injects `runner.runtime` env vars when
/// configured.
pub fn inject_managed_port_env(
  env: List(#(String, String)),
  _trace_id: types_core.TraceId,
  config: types_config.SaarConfig,
  runtime: types_runner.RuntimeConfig,
  assigned_port: Option(Int),
) -> Result(List(#(String, String)), types_output.InteractionError) {
  case assigned_port {
    None -> Ok(env)

    Some(port) ->
      case runtime {
        types_runner.NoNetwork -> Ok(env)

        types_runner.ManagedPort(host_env_var, port_env_var) -> {
          let host = managed_port_host(config)

          let base_env =
            list.append(env, [
              #("SAAR_HOST", host),
              #("SAAR_PORT", int.to_string(port)),
            ])

          let base_env = case host_env_var {
            None -> base_env
            Some(name) -> list.append(base_env, [#(name, host)])
          }

          let base_env = case port_env_var {
            None -> base_env
            Some(name) -> list.append(base_env, [#(name, int.to_string(port))])
          }

          Ok(base_env)
        }
      }
  }
}
