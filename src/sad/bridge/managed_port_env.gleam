//// Managed port environment injection.
////
//// Mission: build the environment variables required for runners started
//// under SAD-managed ports.
////
//// Responsibilities:
//// - Resolve the bind host from `SadConfig`.
//// - Inject `SAD_HOST` and `SAD_PORT` when a port is assigned.
//// - Inject configured `{host_env_var, port_env_var}` for compatibility.
//// - Provide `ManagedPort` environment variables.
////
//// Non-responsibilities:
//// - Starting runner processes.
//// - Performing readiness waits or retry loops.
////
//// Relationships:
//// - Used by `sad/bridge/runner` when starting continuous runners.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import sad/types/config as types_config
import sad/types/core as types_core
import sad/types/output as types_output
import sad/types/runner as types_runner

/// Returns the managed-port host configured in `SadConfig`.
pub fn managed_port_host(config: types_config.SadConfig) -> String {
  let types_config.SadConfig(runner: runner_cfg, ..) = config
  let types_config.RunnerSystemConfig(managed_port_host: host, ..) = runner_cfg
  host
}

/// Builds managed-port environment variables for a runner.
///
/// This always injects `SAD_HOST` and `SAD_PORT` when a port is assigned.
/// It also injects `runner.runtime.{host_env_var,port_env_var}` when configured.
pub fn inject_managed_port_env(
  env: List(#(String, String)),
  _trace_id: types_core.TraceId,
  config: types_config.SadConfig,
  runtime: types_runner.RuntimeConfig,
  assigned_port: Option(Int),
) -> Result(List(#(String, String)), types_output.InteractionError) {
  case assigned_port {
    None -> Ok(env)

    Some(port) -> {
      let host = managed_port_host(config)

      let types_runner.RuntimeConfig(
        mode: mode,
        port_env_var: port_env_var,
        host_env_var: host_env_var,
      ) = runtime

      let base_env =
        list.append(env, [
          #("SAD_HOST", host),
          #("SAD_PORT", int.to_string(port)),
        ])

      let base_env = case host_env_var {
        None -> base_env
        Some(name) -> list.append(base_env, [#(name, host)])
      }

      let base_env = case port_env_var {
        None -> base_env
        Some(name) -> list.append(base_env, [#(name, int.to_string(port))])
      }

      case mode {
        types_runner.ManagedPort -> Ok(base_env)

        types_runner.NoNetwork -> Ok(base_env)
      }
    }
  }
}
