////
//// Mission: build wrapper-related environment variables.
////
//// Responsibilities:
//// - Inject wrapper runtime tuning env vars.
//// - Encode and inject the Landlock policy JSON for the wrapper.
////
//// Non-responsibilities:
//// - Parsing configuration sources.
//// - Starting runner processes.
////
//// Relationships:
//// - Used by `saar/bridge/runner` and `saar/bridge/interaction`.
//// - Consumes `saar/types/config` values.

import envoy
import filepath
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import saar/types/config as types_config
import saar/types/enums as types_enums

/// Appends wrapper-specific environment variables.
///
/// This is a pure helper that keeps wrapper env construction consistent across
/// the transient and streaming code paths.
pub fn append(
  env: List(#(String, String)),
  wrapper: types_config.WrapperConfig,
  shutdown_timeout_ms: Int,
  landlock_mode: types_enums.LandlockMode,
  landlock_policy: Option(types_config.LandlockPolicyConfig),
  workspace: String,
) -> List(#(String, String)) {
  append_with_allowlists(
    env,
    wrapper,
    shutdown_timeout_ms,
    landlock_mode,
    landlock_policy,
    workspace,
    [],
    [],
  )
}

pub fn append_with_allowlists(
  env: List(#(String, String)),
  wrapper: types_config.WrapperConfig,
  shutdown_timeout_ms: Int,
  landlock_mode: types_enums.LandlockMode,
  landlock_policy: Option(types_config.LandlockPolicyConfig),
  workspace: String,
  extra_allow_read: List(String),
  extra_allow_exec: List(String),
) -> List(#(String, String)) {
  let types_config.WrapperConfig(
    read_buffer_bytes: read_buffer_bytes,
    control_line_bytes: control_line_bytes,
    poll_interval_ms: poll_interval_ms,
    post_kill_wait_ms: post_kill_wait_ms,
  ) = wrapper

  let base = [
    #("SAAR_SHUTDOWN_MS", int.to_string(shutdown_timeout_ms)),
    #("SAAR_WRAPPER_READ_BUFFER_BYTES", int.to_string(read_buffer_bytes)),
    #("SAAR_WRAPPER_CONTROL_LINE_BYTES", int.to_string(control_line_bytes)),
    #("SAAR_WRAPPER_POLL_MS", int.to_string(poll_interval_ms)),
    #("SAAR_WRAPPER_POST_KILL_WAIT_MS", int.to_string(post_kill_wait_ms)),
    #("SAAR_LANDLOCK_MODE", types_enums.landlock_mode_to_string(landlock_mode)),
  ]

  let policy_json =
    landlock_policy_json(
      landlock_policy,
      workspace,
      extra_allow_read,
      extra_allow_exec,
    )

  let policy = case policy_json {
    option.Some(policy_json) -> [#("SAAR_LANDLOCK_POLICY_JSON", policy_json)]
    option.None -> []
  }

  let debug_env = case envoy.get("SAAR_DEBUG_LOG_STDOUT") {
    Ok("1") -> [#("DEBUG", "1")]
    Ok("true") -> [#("DEBUG", "1")]
    _ -> []
  }

  list.append(env, list.append(base, list.append(policy, debug_env)))
}

fn landlock_policy_json(
  policy_opt: Option(types_config.LandlockPolicyConfig),
  workspace: String,
  extra_allow_read: List(String),
  extra_allow_exec: List(String),
) -> Option(String) {
  case policy_opt {
    option.None -> option.None
    option.Some(policy0) -> {
      let types_config.LandlockPolicyConfig(
        allow_read: allow_read0,
        allow_exec: allow_exec0,
        allow_write: allow_write0,
      ) = policy0

      let allow_read =
        unique_paths(list.append(allow_read0, [workspace, ..extra_allow_read]))
      let allow_exec =
        unique_paths(list.append(allow_exec0, [workspace, ..extra_allow_exec]))
      let allow_write = list.append(allow_write0, [workspace])

      json.object([
        #("allow_read", json.array(allow_read, json.string)),
        #("allow_exec", json.array(allow_exec, json.string)),
        #("allow_write", json.array(allow_write, json.string)),
      ])
      |> json.to_string
      |> option.Some
    }
  }
}

pub fn runner_allowlists_for_command(
  runner_path: String,
  runner_args: List(String),
) -> #(List(String), List(String)) {
  let #(base_read, base_exec) = runner_allowlists(runner_path)
  let #(arg_read, arg_exec) = case runner_args {
    [script, ..] -> runner_allowlists(script)
    _ -> #([], [])
  }

  let allow_read = unique_paths(list.append(base_read, arg_read))
  let allow_exec = unique_paths(list.append(base_exec, arg_exec))

  #(allow_read, allow_exec)
}

fn runner_allowlists(runner_path: String) -> #(List(String), List(String)) {
  let dir = filepath.directory_name(runner_path)
  case filepath.is_absolute(dir) {
    True -> #([dir], [dir])
    False -> #([], [])
  }
}

fn unique_paths(paths: List(String)) -> List(String) {
  list.fold(paths, [], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> [item, ..acc]
    }
  })
  |> list.reverse
}
